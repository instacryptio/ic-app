import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge/bridge.gen.dart';
import 'app/app.dart';

/// Available titlebar styles.
enum CustomTitlebarStyle { native, defaultStyle, clean, custom }

/// The current titlebar style.
final ValueNotifier<CustomTitlebarStyle> titlebarStyle = ValueNotifier<CustomTitlebarStyle>(
  CustomTitlebarStyle.clean,
);

/// Switch the titlebar style at runtime.
Future<void> setTitlebarStyle(CustomTitlebarStyle style) async {
  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    await windowManager.setTitleBarStyle(
      style == CustomTitlebarStyle.native
          ? TitleBarStyle.normal
          : TitleBarStyle.hidden,
    );
  }
  titlebarStyle.value = style;
}
// --- flugo deep linking (instacrypt://) ---------------------------------

typedef FlugoDeepLinkHandler = void Function(Uri uri);
FlugoDeepLinkHandler? _deepLinkHandler;
final List<Uri> _pendingDeepLinks = [];

/// flugoOnDeepLink registers the app's deep-link handler. Links that arrived
/// before registration (cold start) are delivered immediately, in order.
void flugoOnDeepLink(FlugoDeepLinkHandler handler) {
  _deepLinkHandler = handler;
  final pending = List<Uri>.of(_pendingDeepLinks);
  _pendingDeepLinks.clear();
  pending.forEach(handler);
}

void _dispatchDeepLink(Uri uri) {
  if (uri.scheme != 'instacrypt') return;
  final h = _deepLinkHandler;
  if (h == null) {
    _pendingDeepLinks.add(uri);
    return;
  }
  h(uri);
}

Uri? _uriFromArgs(List<String> args) {
  for (final a in args) {
    final uri = Uri.tryParse(a.trim());
    if (uri != null && uri.scheme == 'instacrypt') return uri;
  }
  return null;
}

Future<void> _initDeepLinks(List<String> args) async {
  if (Platform.isLinux) {
    // app_links has no Linux support: the URI arrives as a launch argument
    // (Exec=%u in the .desktop). _linuxSingleInstance already ran in main()
    // — by the time we get here this process owns the socket.
    final uri = _uriFromArgs(args);
    if (uri != null) _dispatchDeepLink(uri);
    return;
  }
  if (Platform.isWindows) {
    // Protocol activation delivers the URI as an argument; the HKCU
    // registration is written by the Go backend at startup. A running
    // instance is not forwarded to (cold-start links only).
    final uri = _uriFromArgs(args);
    if (uri != null) _dispatchDeepLink(uri);
    return;
  }
  final appLinks = AppLinks();
  final initial = await appLinks.getInitialLink();
  if (initial != null) _dispatchDeepLink(initial);
  appLinks.uriLinkStream.listen(_dispatchDeepLink);
}

/// _linuxSingleInstance forwards a second launch (e.g. a clicked link) to
/// the running instance over a unix socket and exits it; the first instance
/// listens and dispatches forwarded URIs after focusing the window.
Future<void> _linuxSingleInstance(List<String> args) async {
  if (!Platform.isLinux) return;
  final runtimeDir = Platform.environment['XDG_RUNTIME_DIR'] ?? Directory.systemTemp.path;
  final sockPath = '$runtimeDir/ic_app-deeplink.sock';
  final addr = InternetAddress(sockPath, type: InternetAddressType.unix);

  try {
    final sock = await Socket.connect(addr, 0, timeout: const Duration(milliseconds: 300));
    sock.writeln(_uriFromArgs(args)?.toString() ?? '');
    await sock.flush();
    sock.destroy();
    exit(0);
  } catch (_) {
    // No running instance — this process becomes it.
  }

  try {
    final stale = File(sockPath);
    if (stale.existsSync()) stale.deleteSync();
    final server = await ServerSocket.bind(addr, 0);
    server.listen((client) {
      client
          .cast<List<int>>()
          .transform(const Utf8Decoder())
          .transform(const LineSplitter())
          .listen((line) async {
        await windowManager.show();
        await windowManager.focus();
        final uri = Uri.tryParse(line.trim());
        if (uri != null) _dispatchDeepLink(uri);
      });
    });
  } catch (_) {
    // Socket unavailable — deep links still work on cold start.
  }
}

void main(List<String> args) async {
  await _linuxSingleInstance(args);
  // Load the Go shared library.
  final libPath = _libraryPath();
  final lib = libPath != null ? DynamicLibrary.open(libPath) : DynamicLibrary.process();
  FlugoBridge.init(lib, libPath);

  WidgetsFlutterBinding.ensureInitialized();

  // Set the app's base and temp directories on all platforms before any backend calls.
  final appDir = await getApplicationSupportDirectory();
  await FlugoBridge.callAsync('flugoPathService.SetBaseDir', [appDir.path]);
  final tmpDir = await getTemporaryDirectory();
  await FlugoBridge.callAsync('flugoPathService.SetTmpDir', ['${tmpDir.path}/flugo_tmp']);

  if (Platform.isLinux || Platform.isMacOS || Platform.isWindows) {
    await windowManager.ensureInitialized();

    WindowOptions windowOptions = const WindowOptions(
      size: Size(480, 720),
      minimumSize: Size(360, 480),
      titleBarStyle: TitleBarStyle.hidden,
    );

    // Fire-and-forget: the window-show happens after main() continues to
    // runApp(). Wrap in unawaited so the analyzer doesn't flag the dropped
    // Future.
    unawaited(windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    }));
  }
  unawaited(_initDeepLinks(args));
  runApp(const App());
}

String? _libraryPath() {
  if (Platform.isLinux) return 'libbackend.so';
  if (Platform.isMacOS) {
    // In .app bundle: Contents/MacOS/app_name -> Contents/Frameworks/libbackend.dylib
    final exe = Platform.resolvedExecutable;
    final frameworksDir = '${File(exe).parent.parent.path}/Frameworks';
    return '$frameworksDir/libbackend.dylib';
  }
  if (Platform.isWindows) return 'backend.dll';
  if (Platform.isAndroid) return 'libbackend.so';
  if (Platform.isIOS) return null; // uses DynamicLibrary.process()
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}
