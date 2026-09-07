/// The interactive cloud-sync flow plus its security-key/password helpers,
/// MOVED verbatim from the Cloud tab so the home-screen sync icon and
/// Settings → Cloud → Sync Now execute literally the same code path.
///
/// Callers supply their own `run` busy-wrapper (the tab's `_run`, or the
/// home screen's spinner wrapper) and status/error sinks; everything else —
/// hardware-key pre-flight, tap-marker retry, cloud-password prompt, 2FA
/// challenge (email/TOTP/security key) — lives here once.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:webauthn/webauthn.dart';

import '../bridge/bridge.gen.dart';
import 'dialogs.dart' show showTextPromptDialog;
import 'hw_flow.dart' show hwRequiredIdentityFrom, prepareHWForIdentity;
import 'webauthn_support.dart' show isMobileWebAuthnPlatform, mobileWebAuthnGetAssertion;

/// sendCloudPassword ships the password over the raw-bytes secure channel
/// and zeroes the transient buffer immediately after.
Future<void> sendCloudPassword(String pw) async {
  final bytes = Uint8List.fromList(utf8.encode(pw));
  try {
    await cloudService.setPassword(bytes);
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

/// sendSecurityKeyPIN ships the FIDO2 PIN over the secure channel.
Future<void> sendSecurityKeyPIN(String pin) async {
  final bytes = Uint8List.fromList(utf8.encode(pin));
  try {
    await cloudService.setSecurityKeyPIN(bytes);
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

/// withTouchDialog shows the "touch your security key" modal around a
/// WebAuthn ceremony.
Future<bool> withTouchDialog(
  BuildContext context,
  Future<bool> Function(Future<void> Function()) run,
  Future<void> Function() ceremony,
) async {
  if (!context.mounted) return false;
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const AlertDialog(
      content: Row(
        children: [
          SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 16),
          Expanded(child: Text('Touch your security key…')),
        ],
      ),
    ),
  ));
  final ok = await run(ceremony);
  if (context.mounted) {
    Navigator.of(context, rootNavigator: true).pop(); // close touch dialog
  }
  return ok;
}

/// webAuthnAssert runs the security-key login ceremony. On mobile the native
/// plugin drives the OS tap/UV sheet (no PIN dialog); on desktop it's the
/// libfido2 path: PIN dialog → PIN over the secure channel → assertion.
Future<bool> webAuthnAssert(
  BuildContext context,
  Future<bool> Function(Future<void> Function()) run,
  String tempToken,
  String optionsJSON, {
  void Function(String message)? onError,
}) async {
  if (isMobileWebAuthnPlatform) {
    // Run the native ceremony (PIN + present-key prompt) OUTSIDE `run` so a user
    // cancel aborts quietly; the POST goes through `run` for busy state + error UX.
    String? resp;
    try {
      resp = await mobileWebAuthnGetAssertion(context, optionsJSON);
    } on WebauthnException catch (e) {
      if (e.code != 'cancelled') {
        onError?.call('Security key sign-in failed: ${e.message}');
      }
      return false;
    }
    if (resp == null || !context.mounted) return false; // cancelled
    final assertion = resp;
    return run(() => cloudService.logInWebAuthnNative(tempToken, assertion));
  }
  final pin = await showTextPromptDialog(
    context,
    title: 'Security Key PIN',
    label: 'PIN',
    hint: 'Plug the key in first',
    obscure: true,
  );
  if (pin == null || pin.isEmpty || !context.mounted) return false;
  return withTouchDialog(context, run, () async {
    await sendSecurityKeyPIN(pin);
    await cloudService.logInWebAuthn(tempToken, optionsJSON);
  });
}

/// renderSyncOutcomes formats the per-resource sync results into the one
/// summary line both surfaces show. Versions are internal bookkeeping and
/// deliberately not surfaced — they mean nothing to the user.
String renderSyncOutcomes(List<Map<String, dynamic>> outcomes) {
  return outcomes.map((o) {
    final r = o['resource'];
    final err = (o['error'] as String?) ?? '';
    final action = o['action'] as String? ?? '';
    // needs-* actions carry a machine-readable payload in `error`; the flow
    // surfaces them via dialogs, so render friendly text instead of the JSON.
    final actionable =
        action == 'needs-code' || action == 'needs-default-change' || action == 'needs-reseal';
    if (err.isNotEmpty && !actionable) return '$r: $err';
    switch (action) {
      case 'pushed-new':
        return '$r: pushed (new)';
      case 'pushed':
        return '$r: pushed';
      case 'pulled':
        final note = (o['cloud_was_newer'] as bool? ?? false) ? ' (cloud was newer)' : '';
        return '$r: pulled$note';
      case 'up-to-date':
        return '$r: up to date';
      case 'synced':
        return '$r: synced';
      case 'needs-default-change':
        return '$r: default-identity change needs your approval';
      case 'needs-reseal':
        return '$r: orphaned cloud copy needs your approval to re-seal';
      default:
        return '$r: ${o['action']}';
    }
  }).join(' · ');
}

/// runCloudSyncFlow is the full foreground sync: hardware-key pre-flight,
/// the sync itself, one tap-marker retry, the identities cloud-password
/// prompt, and the 2FA challenge — reporting through [onStatus]/[onError].
Future<void> runCloudSyncFlow(
  BuildContext context, {
  required void Function(String message) onStatus,
  required void Function(String message) onError,
  required Future<bool> Function(Future<void> Function()) run,
  required bool webAuthnSupported,
}) async {
  // Proactive hardware-key pre-flight: a HW-backed default identity means
  // the contacts/settings leg will need a staged tap response — collect it
  // up front so the common case never round-trips through a failed sync.
  if ((Platform.isAndroid || Platform.isIOS) && await icfxService.requiresHardwareKey()) {
    final name = await icfxService.defaultIdentityName();
    if (!context.mounted) return;
    final ready = name.isEmpty || await prepareHWForIdentity(context, name);
    if (!ready) return; // user cancelled the tap
  }
  if (!context.mounted) return;
  await _runSync(context,
      onStatus: onStatus, onError: onError, run: run, webAuthnSupported: webAuthnSupported, retried: false);
}

Future<void> _runSync(
  BuildContext context, {
  required void Function(String message) onStatus,
  required void Function(String message) onError,
  required Future<bool> Function(Future<void> Function()) run,
  required bool webAuthnSupported,
  required bool retried,
  String? approvalJSON,
  int approvalDepth = 0,
}) async {
  var outcomes = <Map<String, dynamic>>[];
  final ok = await run(() async {
    // Carry the user's approval of a prior run's pending (default-identity
    // change / re-seal) when present; otherwise a normal sync.
    final raw = approvalJSON == null
        ? await cloudService.sync()
        : await cloudService.syncWithApproval(approvalJSON);
    outcomes = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
  });
  if (!ok || !context.mounted) return;

  // A leg that needs a hardware-key tap (e.g. a non-default identity in
  // pending drain) reports the marker; run the tap flow and retry once.
  for (final o in outcomes) {
    final err = (o['error'] as String?) ?? '';
    final hwIdentity = hwRequiredIdentityFrom(err);
    if (hwIdentity != null && !retried) {
      final ready = await prepareHWForIdentity(context, hwIdentity);
      if (!ready || !context.mounted) break; // cancelled — fall through to banner
      await _runSync(context,
          onStatus: onStatus, onError: onError, run: run, webAuthnSupported: webAuthnSupported, retried: true);
      return;
    }
  }

  // Identities may need the cloud password (fresh process) or a 2FA code.
  for (final o in outcomes) {
    if (o['resource'] != 'identities') continue;
    final err = (o['error'] as String?) ?? '';
    if ((o['action'] as String?) == 'needs-code') {
      await _handleSyncChallenge(context, err,
          onStatus: onStatus, onError: onError, run: run, webAuthnSupported: webAuthnSupported, retried: retried);
      return;
    }
    if (err.contains('cloud password required') && !retried) {
      final pw = await showTextPromptDialog(
        context,
        title: 'Cloud password',
        label: 'Password',
        hint: 'Needed to unlock identity sync',
        obscure: true,
      );
      if (pw == null || pw.isEmpty) break;
      await sendCloudPassword(pw);
      if (!context.mounted) return;
      await _runSync(context,
          onStatus: onStatus, onError: onError, run: run, webAuthnSupported: webAuthnSupported, retried: true);
      return;
    }
  }
  // A default-identity change or an orphaned-resource re-seal is surfaced as a
  // pending the user must approve — never applied silently. Confirm, then re-run
  // carrying the approval token (bounded so a misbehaving server can't loop us).
  if (approvalDepth < 3) {
    for (final o in outcomes) {
      final action = o['action'] as String?;
      if (action != 'needs-default-change' && action != 'needs-reseal') continue;
      final err = (o['error'] as String?) ?? '';
      String? approval;
      if (action == 'needs-default-change') {
        if (!context.mounted) return;
        approval = await _confirmDefaultChange(context, err);
      }
      if (action == 'needs-reseal') {
        if (!context.mounted) return;
        approval = await _confirmReseal(context, err);
      }
      if (approval == null || !context.mounted) return; // declined — leave as-is
      await _runSync(context,
          onStatus: onStatus,
          onError: onError,
          run: run,
          webAuthnSupported: webAuthnSupported,
          retried: retried,
          approvalJSON: approval,
          approvalDepth: approvalDepth + 1);
      return;
    }
  }

  // Per-resource errors go to the red banner; clean runs to the green one. The
  // actionable needs-* pendings are surfaced via dialogs, not the error banner.
  final failed = outcomes.where((o) {
    final action = o['action'] as String?;
    if (action == 'needs-code' || action == 'needs-default-change' || action == 'needs-reseal') {
      return false;
    }
    return ((o['error'] as String?) ?? '').isNotEmpty;
  });
  if (failed.isNotEmpty) {
    onError(renderSyncOutcomes(outcomes));
    return;
  }
  onStatus(renderSyncOutcomes(outcomes));
}

/// _confirmDefaultChange parses a needs-default-change pending and asks the user
/// to approve applying it on this device (the anti-takeover gate: an attacker
/// holding the account key must not silently swap your default). Returns the
/// approval JSON for SyncWithApproval, or null if declined.
Future<String?> _confirmDefaultChange(BuildContext context, String pendingJSON) async {
  Map<String, dynamic> p;
  try {
    p = jsonDecode(pendingJSON) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  final kind = (p['kind'] as String?) ?? '';
  final current = (p['current'] as String?) ?? '';
  final incoming = (p['incoming'] as String?) ?? '';
  final body = kind == 'key'
      ? 'A cloud sync wants to replace the keys of your default identity "$current" '
          '(a rotation or key-swap from another device). Apply it on this device?'
      : 'A cloud sync wants to change this device\'s default identity from "$current" '
          'to "$incoming" (chosen on another device). Apply it on this device?';
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Approve default-identity change?'),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Keep current')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Apply')),
      ],
    ),
  );
  if (ok != true) return null;
  return jsonEncode({
    'default_change': {'kind': kind, 'incoming': incoming},
  });
}

/// _confirmReseal parses a needs-reseal pending and asks before overwriting the
/// orphaned cloud copies from this device's local data (re-seeding can drop
/// cloud-only state, so it must be a deliberate choice). Returns approval JSON,
/// or null if declined.
Future<String?> _confirmReseal(BuildContext context, String pendingJSON) async {
  Map<String, dynamic> p;
  try {
    p = jsonDecode(pendingJSON) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  final resources = ((p['resources'] as List<dynamic>?) ?? const []).cast<String>();
  if (resources.isEmpty) return null;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Recover orphaned cloud data?'),
      content: Text(
        'These cloud resources are sealed to a superseded key: ${resources.join(', ')}.\n\n'
        "Recover them by overwriting the cloud copy with THIS device's local copy, "
        'sealed to your current default. Any changes that live only in the cloud will '
        'be replaced by what is on this device.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Re-seal')),
      ],
    ),
  );
  if (ok != true) return null;
  return jsonEncode({'reseal': resources});
}

Future<void> _handleSyncChallenge(
  BuildContext context,
  String challengeJSON, {
  required void Function(String message) onStatus,
  required void Function(String message) onError,
  required Future<bool> Function(Future<void> Function()) run,
  required bool webAuthnSupported,
  required bool retried,
}) async {
  if (retried) return; // one retry only — avoid loops
  Map<String, dynamic> parsed;
  try {
    parsed = jsonDecode(challengeJSON) as Map<String, dynamic>;
  } catch (_) {
    onError('Unexpected sync challenge.');
    return;
  }
  final factor = (parsed['factor'] as String?) ?? '';
  final temp = (parsed['temp_token'] as String?) ?? '';
  if (factor == 'webauthn') {
    if (!webAuthnSupported) {
      onError("This account needs its hardware key — sign in via the desktop app or CLI.");
      return;
    }
    final options = parsed['webauthn'] != null ? jsonEncode(parsed['webauthn']) : '';
    final done = await webAuthnAssert(context, run, temp, options, onError: onError);
    if (!done || !context.mounted) return;
    await _runSync(context,
        onStatus: onStatus, onError: onError, run: run, webAuthnSupported: webAuthnSupported, retried: true);
    return;
  }
  final code = await showTextPromptDialog(
    context,
    title: 'Two-factor code',
    label: 'Code',
    hint: factor == 'email' ? 'Enter the code we emailed you' : 'Enter the code from your authenticator',
  );
  if (code == null || code.isEmpty) return;
  final ok = await run(() async {
    if (factor == 'email') {
      await cloudService.logInEmail(temp, code);
      return;
    }
    await cloudService.logInTOTP(temp, code);
  });
  if (!ok || !context.mounted) return;
  await _runSync(context,
      onStatus: onStatus, onError: onError, run: run, webAuthnSupported: webAuthnSupported, retried: true);
}
