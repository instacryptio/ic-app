/// Shared session-unlock ceremony — VERBATIM move of HomePage's
/// `_ensureUnlocked` (same pattern as sync_flow.dart) so every entry point
/// that runs a crypto op (home screen, notifications drawer) drives ONE
/// unlock code path instead of reimplementing it.
///
/// Follows the dialogs.dart contract: context + callbacks in, Future out.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../bridge/bridge.gen.dart';
import 'dialogs.dart';

/// ensureSessionUnlocked runs the full pre-op unlock ceremony: HW-presence
/// check (desktop), session passphrase prompt when locked. Returns false
/// when the user cancels. [onError] receives unlock failures (each caller
/// surfaces them in its own UI — status line, drawer error, etc.).
Future<bool> ensureSessionUnlocked(
  BuildContext context, {
  required void Function(String message) onError,
}) async {
  // HW PRESENCE — unconditional for HW-protected default identities. Must
  // run BEFORE the isUnlocked() short-circuit because isUnlocked returns
  // true for keychain-only setups (no file-backed identities exist), which
  // would otherwise silently bypass the prompt and let the user reach the
  // home screen without their HW key. The actual challenge-response runs
  // organically on the next crypto op (via openIdentity in encrypt/decrypt)
  // and at launch (via _verifyDefaultHWAtLaunch).
  if (await icfxService.requiresHardwareKey()) {
    // Desktop only: poll for a USB-plugged-in device via go-hid
    // before asking for a passphrase. On mobile, `hasAnyHardwareKey`
    // is chalresp-backed and always returns false (chalresp is
    // stubbed on android/ios). Both NFC and USB-OTG transports are
    // detected later inside the hardware_key plugin's discovery
    // (started via prepareHWForIdentity); the plugin runs both
    // listeners in parallel and the first to fire wins.
    if (!Platform.isAndroid && !Platform.isIOS) {
      while (!await icfxService.hasAnyHardwareKey()) {
        if (!context.mounted) return false;
        final retry = await showHWNotPluggedInDialog(context);
        if (!retry) return false;
      }
    }
  }

  try {
    if (await icfxService.isUnlocked()) return true;
  } on FlugoException {
    // Fall through to the prompt below.
  }

  // If the default identity doesn't need a passphrase (keychain backend,
  // HW or not), skip the Unlock call entirely. IsUnlocked already returned
  // false because OTHER identities use the file backend, but unlocking
  // those requires their own passphrase prompt at the time they're used
  // — which callers handle via the "passphrase required" retry.
  if (!await icfxService.requiresPassphrase()) {
    return true;
  }

  if (!context.mounted) return false;
  final ppBytes = await showPassphraseDialog(context);
  if (ppBytes == null) return false;
  try {
    await icfxService.unlock(ppBytes);
    return true;
  } on FlugoException catch (e) {
    onError('Unlock failed: $e');
    return false;
  } finally {
    // Wipe the bytes regardless of success/failure. The Go side already
    // wiped the C-allocated copy; this zeroes the Dart-side Uint8List.
    ppBytes.fillRange(0, ppBytes.length, 0);
  }
}
