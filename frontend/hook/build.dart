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

    // macOS: set SDKROOT so the linker finds SDK libraries (e.g. libresolv)
    if (goos == 'darwin') {
      final sdkResult = await Process.run('xcrun', ['--show-sdk-path']);
      if (sdkResult.exitCode == 0) {
        env['SDKROOT'] = sdkResult.stdout.toString().trim();
      }
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
