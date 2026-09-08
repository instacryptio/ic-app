// hook/build.dart -- Native assets build hook for Flutter.
// Compiles the Go backend automatically during `flutter build`.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    // packageRoot ends with a trailing slash; resolve to a clean absolute
    // path (a lingering `..` breaks the dependency URIs declared below).
    final backendDir =
        Directory('${input.packageRoot.toFilePath()}../backend').resolveSymbolicLinksSync();
    final outDir = input.outputDirectory;

    final target = input.config.code.targetOS;
    final arch = input.config.code.targetArchitecture;

    String outputName;
    String goos;
    String goarch;

    switch (target) {
      case OS.linux:
        outputName = 'libbackend.so';
        goos = 'linux';
      case OS.macOS:
        outputName = 'libbackend.dylib';
        goos = 'darwin';
      case OS.windows:
        outputName = 'backend.dll';
        goos = 'windows';
      default:
        // Mobile builds handled separately via gomobile.
        return;
    }

    switch (arch) {
      case Architecture.x64:
        goarch = 'amd64';
      case Architecture.arm64:
        goarch = 'arm64';
      default:
        goarch = 'amd64';
    }

    final outputPath = '${outDir.toFilePath()}/$outputName';

    final goArgs = ['build', '-buildmode=c-shared'];
    // macOS doesn't have libresolv — use Go's pure-Go DNS resolver
    if (goos == 'darwin') {
      goArgs.addAll(['-tags', 'netgo']);
    }
    goArgs.addAll(['-o', outputPath, '.']);

    final env = {
      'CGO_ENABLED': '1',
      'GOOS': goos,
      'GOARCH': goarch,
    };

    // macOS: set SDKROOT so the linker finds SDK libraries (e.g. libresolv).
    if (goos == 'darwin') {
      final sdkResult = await Process.run('xcrun', ['--show-sdk-path']);
      if (sdkResult.exitCode == 0) {
        env['SDKROOT'] = sdkResult.stdout.toString().trim();
      }
      // The Flutter hooks runner runs this hook in a semi-hermetic environment:
      // it strips everything except an allowlist (PATH survives; PKG_CONFIG_PATH
      // and CGO_* do NOT). So any cgo flags a CI script exports never reach this
      // `go build`. If the backend links Homebrew C libs (keg-only ones like
      // openssl@3 keep their headers/.pc under opt/<name>), cgo can't find them.
      // Discover Homebrew ourselves (brew resolves via the inherited PATH) and
      // set the cgo env explicitly here. No-op when Homebrew isn't installed —
      // a pure-Go backend just proceeds with none of this set.
      await _applyHomebrewCgoEnv(env);
    }

    // Windows: same hermetic-env problem — PKG_CONFIG_PATH is stripped, so cgo
    // `#cgo pkg-config:` directives (e.g. a system libfido2/ykpers linked from
    // MSYS2) can't find their .pc files. PATH survives, so locate pkg-config and
    // derive the mingw prefix's lib/pkgconfig.
    if (goos == 'windows') {
      await _applyMsys2PkgConfig(env);
    }

    final result = await Process.run(
      'go',
      goArgs,
      workingDirectory: backendDir,
      environment: env,
    );

    if (result.exitCode != 0) {
      throw Exception('Go build failed:\n${result.stderr}');
    }

    output.assets.code.add(
      CodeAsset(
        package: 'ic_app',
        name: 'backend',
        linkMode: DynamicLoadingBundled(),
        file: Uri.file(outputPath),
      ),
    );

    // Declare the Go source inputs so edits re-run this hook. With NO
    // declared dependencies the hooks runner caches the output until the
    // build config changes — `flutter run` would keep bundling a stale
    // library and Go's own build cache never gets a chance to run.
    // File-level dependencies only (never directories or build outputs),
    // so `go build` can't trip the "file modified during build" loop.
    output.dependencies.addAll(_goSourceDeps(backendDir));
  });
}

/// Makes Homebrew's pkg-config metadata visible to the backend's cgo build on
/// macOS.
///
/// The hooks runner strips PKG_CONFIG_PATH before this hook starts (PATH
/// survives), so cgo `#cgo pkg-config:` directives can't find keg-only kegs and
/// fail with "<lib>.h file not found". `brew` still resolves via the inherited
/// PATH, so rebuild PKG_CONFIG_PATH here from every Homebrew pkgconfig dir,
/// including keg-only formulae (openssl@3, ykpers, …) whose .pc files live under
/// opt/<name>/lib/pkgconfig. That alone resolves the libs and their transitive
/// Requires; deliberately no CGO_CFLAGS/CGO_LDFLAGS injection (a blanket -I on
/// the brew prefix can shadow the macOS SDK's own headers). No-op when `brew`
/// isn't on PATH — a pure-Go backend just proceeds without it.
Future<void> _applyHomebrewCgoEnv(Map<String, String> env) async {
  final brew = await Process.run('brew', ['--prefix']);
  if (brew.exitCode != 0) return;
  final prefix = brew.stdout.toString().trim();
  if (prefix.isEmpty) return;

  final pcDirs = <String>['$prefix/lib/pkgconfig', '$prefix/share/pkgconfig'];
  // Keg-only formulae aren't linked into the shared prefix; their .pc files
  // live under opt/<name>/lib/pkgconfig. Extra dirs are inert to pkg-config
  // (it only reads the .pc files a directive names), so this glob is safe.
  final optDir = Directory('$prefix/opt');
  if (optDir.existsSync()) {
    // opt/<formula> entries are SYMLINKS into Cellar, so list without following
    // links and test each candidate pkgconfig dir directly — Directory.existsSync
    // follows the symlink. Gating on `entry is Directory` would skip every keg
    // (a symlink lists as a Link, not a Directory) and defeat the whole point.
    for (final entry in optDir.listSync(followLinks: false)) {
      final pc = Directory('${entry.path}/lib/pkgconfig');
      if (pc.existsSync()) pcDirs.add(pc.path);
    }
  }
  env['PKG_CONFIG_PATH'] = pcDirs.join(':');

  // Homebrew's prefix is NOT a default compiler search path on macOS (unlike
  // Linux's /usr), and some formulae's pkg-config Cflags point one level too
  // deep — e.g. ykpers-1.pc yields `-I<prefix>/include/ykpers-1`, but the code
  // does `#include <ykpers-1/ykcore.h>`, which needs the parent `include/` on
  // the search path. Add the umbrella include/lib so those headers/libs resolve.
  env['CGO_CFLAGS'] = '-I$prefix/include';
  env['CGO_LDFLAGS'] = '-L$prefix/lib';
}

/// Makes MSYS2/mingw's pkg-config metadata visible to the backend's cgo build
/// on Windows.
///
/// The hooks runner strips PKG_CONFIG_PATH before this hook runs, and mingw
/// pkgconf's compiled-in default may not cover the mingw prefix's lib/pkgconfig.
/// PATH survives, so locate `pkg-config` on it (it lives in <prefix>/bin) and
/// derive <prefix>/lib/pkgconfig. No-op if pkg-config isn't found — a pure-Go
/// backend just proceeds without it.
Future<void> _applyMsys2PkgConfig(Map<String, String> env) async {
  final located = await Process.run('where', ['pkg-config']);
  if (located.exitCode != 0) return;
  final first = located.stdout
      .toString()
      .split(RegExp(r'[\r\n]+'))
      .map((s) => s.trim())
      .firstWhere((s) => s.isNotEmpty, orElse: () => '');
  if (first.isEmpty) return;
  // <prefix>/bin/pkg-config(.exe) -> <prefix>/lib/pkgconfig
  final prefix = File(first).parent.parent.path;
  final pc = Directory('$prefix/lib/pkgconfig');
  if (pc.existsSync()) env['PKG_CONFIG_PATH'] = pc.path;
}

/// Enumerates the Go sources the backend build depends on: the backend
/// module itself plus any LOCAL `replace` targets in its go.mod (shared
/// libraries in sibling directories), recursively.
List<Uri> _goSourceDeps(String backendDir) {
  final seen = <String>{};
  final deps = <Uri>[];

  void addFile(File f) {
    final p = f.absolute.path;
    if (seen.add(p)) deps.add(f.absolute.uri);
  }

  void walk(Directory d) {
    final List<FileSystemEntity> entries;
    try {
      entries = d.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final e in entries) {
      final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
      if (e is Directory) {
        // Skip VCS, build outputs, and non-Go trees.
        if (name.startsWith('.') || name == 'build' || name == 'frontend' || name == 'node_modules') {
          continue;
        }
        walk(e);
        continue;
      }
      if (e is File && (name.endsWith('.go') || name == 'go.mod' || name == 'go.sum')) {
        addFile(e);
      }
    }
  }

  final roots = <String>[backendDir];
  final goMod = File('$backendDir/go.mod');
  if (goMod.existsSync()) {
    // Local replace directives: `replace example.com/x => ../path` (inline or
    // inside a replace block). Only relative targets are local source trees.
    final localTarget = RegExp(r'=>\s+(\.\.?/\S+)');
    for (final line in goMod.readAsLinesSync()) {
      final m = localTarget.firstMatch(line);
      if (m == null) continue;
      final dir = Directory('$backendDir/${m.group(1)!}');
      // Normalize away the `..` segments — dependency URIs must be clean
      // absolute paths or the hooks runner can't stat/hash them.
      if (dir.existsSync()) roots.add(dir.resolveSymbolicLinksSync());
    }
  }
  for (final root in roots) {
    final dir = Directory(root);
    if (dir.existsSync()) walk(dir);
  }
  return deps;
}
