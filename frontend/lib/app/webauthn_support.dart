// Platform seam for WebAuthn security-key ceremonies.
//
// Desktop drives FIDO2 via the libfido2-backed Go authenticator. Mobile drives
// it via the flugo `webauthn` plugin — on Android a Play-Services-FREE CTAP2
// client over USB/NFC (works on GrapheneOS), on iOS AuthenticationServices. The
// mobile ceremony needs a PIN (for the key's user verification) and a
// "present your key" prompt while the plugin waits for a tap/insert; these
// helpers keep the call sites platform-agnostic.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:webauthn/webauthn.dart';

import '../bridge/bridge.gen.dart';
import 'dialogs.dart' show showTextPromptDialog;

/// Whether this build uses the native mobile WebAuthn plugin (vs desktop libfido2).
bool get isMobileWebAuthnPlatform => Platform.isAndroid || Platform.isIOS;

/// Whether THIS device can complete an external-security-key ceremony: desktop →
/// the libfido2-backed Go check; mobile → the native plugin's availability
/// (Android: USB host or NFC present; iOS: AuthenticationServices).
Future<bool> platformWebAuthnSupported() async {
  if (isMobileWebAuthnPlatform) {
    return WebauthnPlugin.isAvailable();
  }
  return cloudService.webAuthnSupported();
}

/// mobileWebAuthnGetAssertion runs a login (assertion) ceremony on mobile,
/// returning the response JSON for the backend, or null if the user cancels.
/// Throws [WebauthnException] on a real failure (surfaced by the caller).
Future<String?> mobileWebAuthnGetAssertion(BuildContext context, String optionsJson) {
  return _mobileCeremony(
    context,
    (origin, pin) => WebauthnPlugin.getAssertion(optionsJson, origin: origin, pin: pin),
  );
}

/// mobileWebAuthnEnroll registers a new security key on mobile: fetch creation
/// options from the server, run the native attestation ceremony, submit it.
Future<void> mobileWebAuthnEnroll(BuildContext context, String label) async {
  final beginJson = await cloudService.webAuthnRegisterBeginNative(label);
  final begin = jsonDecode(beginJson) as Map<String, dynamic>;
  final options = jsonEncode(begin['options']);
  final handle = begin['handle'] as String;
  if (!context.mounted) return;
  final resp = await _mobileCeremony(
    context,
    (origin, pin) => WebauthnPlugin.makeCredential(options, origin: origin, pin: pin),
  );
  if (resp == null) return; // cancelled
  await cloudService.webAuthnRegisterFinishNative(handle, resp);
}

/// _mobileCeremony collects the PIN, shows a "present your key" prompt while the
/// plugin waits for a tap/insert, and runs [op] (get/make) with the cloud origin
/// (self-asserted, like desktop). Returns the response JSON, or null if the user
/// cancels the PIN dialog. Rethrows [WebauthnException] from the ceremony.
Future<String?> _mobileCeremony(
  BuildContext context,
  Future<String> Function(String origin, String pin) op,
) async {
  final origin = await cloudService.webAuthnOrigin();
  if (!context.mounted) return null;
  final pin = await showTextPromptDialog(
    context,
    title: 'Security key PIN',
    label: 'PIN',
    hint: "Your security key's PIN (leave blank if it has none)",
    obscure: true,
  );
  if (pin == null || !context.mounted) return null; // user cancelled
  final future = op(origin, pin);
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Present your security key'),
      content: const Text(
          'Tap your key to the back of the phone (NFC), or plug it into USB-C.'),
      actions: [
        // Cancels the in-flight ceremony → the future throws → finally dismisses this.
        TextButton(
          onPressed: () => WebauthnPlugin.cancelAssertion(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  ));
  try {
    return await future;
  } finally {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }
}
