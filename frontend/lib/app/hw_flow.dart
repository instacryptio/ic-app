// Mobile hardware-key orchestration. Extracted from app.dart so the
// State class doesn't carry the NFC tap dance — same split rationale
// as dialogs.dart / home_controller.dart / profile_flow.dart.
//
// Desktop: chalresp talks to the device synchronously inside each crypto
// op via libykpers — none of this code runs except `ensureHWForNewIdentity`
// (which falls back to the existing presence-loop).
//
// Mobile: the Go side can't reach NFC. The Dart layer does the dance:
//   1. Get the per-identity challenge bytes (read from disk for existing
//      identities, generated server-side for new ones).
//   2. Show the "tap your key" sheet.
//   3. Call the flugo hardware_key plugin to do the actual NFC tap +
//      challenge-response (HMAC-SHA1) — same call covers USB-OTG on
//      Android, MFi Lightning on iOS [B.2].
//   4. Inject the 20-byte response into Go's per-identity cache via
//      InjectHWResponse so the subsequent crypto op (or CreateKeys)
//      can derive the KEK.
//
// One tap per crypto op — NFC is atomic. The cache wipes on auto-lock /
// Lock alongside sessionPass.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hardware_key/hardware_key.dart';

import '../bridge/bridge.gen.dart';
import 'dialogs.dart';
import 'settings_shared.dart' show showMessageDialog;

/// prepareHWForIdentity fetches a per-identity HMAC-SHA1 response from
/// the user's hardware key for an EXISTING identity and injects it into
/// the Go cache so the next crypto op against this identity can decrypt.
/// Returns true if a response is ready (or not needed); false if the
/// user cancelled or no key responded.
///
/// Desktop: no-op (chalresp handles HW inline).
Future<bool> prepareHWForIdentity(BuildContext context, String identityName) async {
  if (!Platform.isAndroid && !Platform.isIOS) return true;
  if (identityName.isEmpty) return true;

  // If a fresh response is already cached (rare — usually each op
  // re-taps), skip the round trip.
  if (await icfxService.hasHWResponse(identityName)) return true;

  // The challenge file only exists for HW-protected identities. A
  // missing file means the identity isn't HW-protected — nothing to do.
  Uint8List challenge;
  try {
    challenge = await icfxService.getHWChallenge(identityName);
  } on FlugoException {
    return true;
  }

  if (!context.mounted) return false;
  return _runChallengeFlow(context, identityName, challenge);
}

/// prepareHWForNewIdentity is the create-path analogue of
/// prepareHWForIdentity. The identity doesn't exist yet — there's no
/// challenge file to read — so we ask Go to generate a fresh random
/// challenge, drive the NFC tap against it, and inject the response.
/// CreateKeys consumes both the cached challenge (persists it to disk)
/// and the cached response (derives the KEK).
///
/// Desktop: no-op (desktop CreateKeys path generates + persists the
/// challenge inline via libykpers).
Future<bool> prepareHWForNewIdentity(BuildContext context, String identityName) async {
  if (!Platform.isAndroid && !Platform.isIOS) return true;
  if (identityName.isEmpty) return true;

  final Uint8List challenge;
  try {
    challenge = await icfxService.generateHWChallenge(identityName);
  } on FlugoException catch (e) {
    if (!context.mounted) return false;
    await showMessageDialog(context, 'Hardware Key Error', '$e');
    return false;
  }

  if (!context.mounted) return false;
  return _runChallengeFlow(context, identityName, challenge);
}

/// ensureHWForNewIdentity is the platform-dispatch entry point used by
/// `_createKeys` in app.dart. On mobile, drives the NFC tap dance via
/// prepareHWForNewIdentity. On desktop, runs the existing
/// is-a-key-plugged-in presence loop (so CreateKeys' libykpers smoke
/// test doesn't fail with a confusing "no device" error after the user
/// already submitted the create form).
Future<bool> ensureHWForNewIdentity(BuildContext context, String identityName) async {
  if (Platform.isAndroid || Platform.isIOS) {
    return prepareHWForNewIdentity(context, identityName);
  }
  while (!await icfxService.hasAnyHardwareKey()) {
    if (!context.mounted) return false;
    final retry = await showHWNotPluggedInDialog(context);
    if (!retry) return false;
  }
  return true;
}

/// prepareHWForImport is the import-path analogue of prepareHWForIdentity /
/// prepareHWForNewIdentity: it drives the NFC tap against the challenge carried
/// IN THE INCOMING BUNDLE (not read from disk, not generated) and injects the
/// response so ImportIdentity / ImportProfile can re-bind HW protection on this
/// device. Keyed by identityName to match Go's openHWForOp(name).
///
/// Desktop: runs the existing is-a-key-plugged-in presence loop (desktop import
/// uses openDesktopHWChalresp inline).
Future<bool> prepareHWForImport(
  BuildContext context,
  String identityName,
  Uint8List bundleChallenge,
) async {
  if (Platform.isAndroid || Platform.isIOS) {
    if (identityName.isEmpty || bundleChallenge.isEmpty) return false;
    return _runChallengeFlow(context, identityName, bundleChallenge);
  }
  while (!await icfxService.hasAnyHardwareKey()) {
    if (!context.mounted) return false;
    final retry = await showHWNotPluggedInDialog(context);
    if (!retry) return false;
  }
  return true;
}

/// _runChallengeFlow drives the dialog + plugin race shared by both the
/// read-path (prepareHWForIdentity) and the create-path
/// (prepareHWForNewIdentity). Shows the tap sheet, invokes the
/// hardware_key plugin's challengeResponse, races the user's Cancel
/// against the plugin's completion, then injects the response into Go.
Future<bool> _runChallengeFlow(
  BuildContext context,
  String identityName,
  Uint8List challenge,
) async {
  if (!context.mounted) return false;

  var cancelled = false;
  final pluginFuture = HardwareKey.challengeResponse(
    challenge: challenge,
    slot: HardwareKeySlot.slot2,
  );
  final dialogFuture = showNFCTapDialog(
    context,
    onCancel: () {
      cancelled = true;
      HardwareKey.cancel();
    },
  );

  HardwareKeyResponse response;
  try {
    response = await pluginFuture;
  } on HardwareKeyException {
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    await dialogFuture;
    return false;
  }

  // Plugin completed before the user hit Cancel — dismiss the dialog
  // ourselves so the caller's flow continues.
  if (!cancelled && context.mounted) {
    Navigator.of(context, rootNavigator: true).pop();
  }
  await dialogFuture;
  if (cancelled) return false;

  // The 20-byte HMAC response is the keystore KEK factor — stage it over the
  // secure raw-bytes channel, then inject (name + non-secret device metadata).
  await icfxService.stageHWResponse(response.response);
  await icfxService.injectHWResponse(
    identityName,
    response.serial,
    response.family,
  );
  return true;
}

/// hwRequiredIdentityFrom extracts the identity name from a sync outcome's
/// "hardware key required for identity …" marker, or null when the
/// error is unrelated. The marker is emitted by the Go sync legs when a
/// crypto op needs a staged hardware-key response.
String? hwRequiredIdentityFrom(String error) {
  // Must match the backend's canonical errHWRequiredPrefix (cloud.go) exactly.
  const marker = 'hardware key required for identity ';
  final i = error.indexOf(marker);
  if (i < 0) return null;
  final name = error.substring(i + marker.length).trim();
  return name.isEmpty ? null : name;
}
