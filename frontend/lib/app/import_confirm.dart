// Contact-import outcome handling shared by the file-import and QR-import
// flows. The backend classifies every import: a brand-new contact is applied
// immediately (ImportOutcome.applied), while a key rotation/update or a
// revocation for an EXISTING contact is cached under a one-time token and must
// be confirmed by the user before it is applied. This is the security-sensitive
// moment — the user is swapping the stored Lock (public key) for a contact — so
// the confirm dialog shows the old→new fingerprint for out-of-band
// verification.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../bridge/bridge.gen.dart';
import 'ic_share.dart' show cleanBridgeError;
import 'settings_shared.dart' show showMessageDialog;

/// Parsed result of a contact import (the JSON returned by ImportLockFile /
/// ImportLockQR, or the nested "result" of an ImportLockQRPart completion).
class ImportOutcome {
  const ImportOutcome({
    required this.action,
    required this.applied,
    required this.token,
    required this.name,
    required this.message,
    required this.oldFingerprint,
    required this.newFingerprint,
  });

  /// 0 = add, 1 = update (key rotation), 2 = revoke.
  final int action;

  /// True when the backend already applied the import (a brand-new contact).
  final bool applied;

  /// One-time correlation token echoed back to confirmContactImport. Empty for
  /// applied or informational outcomes.
  final String token;

  /// Contact display name.
  final String name;

  /// Human-readable description from the backend.
  final String message;

  /// Grouped fingerprint of the contact's current (or revoked) key.
  final String oldFingerprint;

  /// Grouped fingerprint of the incoming key (empty for a revocation).
  final String newFingerprint;

  factory ImportOutcome.fromJson(Map<String, dynamic> j) => ImportOutcome(
        action: j['action'] as int? ?? 0,
        applied: j['applied'] as bool? ?? false,
        token: j['token'] as String? ?? '',
        name: j['name'] as String? ?? '',
        message: j['message'] as String? ?? '',
        oldFingerprint: j['oldFingerprint'] as String? ?? '',
        newFingerprint: j['newFingerprint'] as String? ?? '',
      );

  factory ImportOutcome.fromJsonString(String s) =>
      ImportOutcome.fromJson(jsonDecode(s) as Map<String, dynamic>);

  /// A key change for an existing contact that must be confirmed before applying.
  bool get needsConfirm => !applied && token.isNotEmpty;

  bool get isRevoke => action == 2;
}

/// Drives the UI for an import outcome:
/// - applied → surface a success message via [onStatus];
/// - needsConfirm → show the fingerprint-verification dialog and, on Apply,
///   call [onConfirm] with the token, then surface the result;
/// - informational (e.g. a revocation for an unknown contact) → [onStatus].
///
/// [onStatus] is how the caller reports terminal feedback through its OWN
/// channel — a snackbar on the home screen, a sheet-local dialog in settings —
/// never the main status bar from within a sheet. It is awaited so a caller
/// about to pop a route can let its message dialog settle first.
Future<void> handleImportOutcome(
  BuildContext context,
  ImportOutcome outcome, {
  required Future<void> Function(String token) onConfirm,
  required Future<void> Function(String message) onStatus,
}) async {
  if (outcome.applied) {
    final who = outcome.name.isNotEmpty ? ': ${outcome.name}' : '';
    await onStatus('Contact imported$who');
    return;
  }
  if (!outcome.needsConfirm) {
    await onStatus(outcome.message);
    return;
  }

  final confirmed = await showImportConfirmDialog(context, outcome);
  if (confirmed != true) return;
  await onConfirm(outcome.token);
  await onStatus(outcome.isRevoke ? 'Contact keys revoked' : 'Contact updated');
}

/// Shows the key-change confirmation dialog with the old→new fingerprint and a
/// verify-identity warning. Returns true if the user chose to apply.
Future<bool?> showImportConfirmDialog(BuildContext context, ImportOutcome o) {
  final title = o.isRevoke
      ? '${o.name} revoked their key'
      : '${o.name} updated their keys';
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (o.message.isNotEmpty) ...[
            Text(o.message),
            const SizedBox(height: 16),
          ],
          _FingerprintRow(
            label: o.isRevoke ? 'Revoked key' : 'Old key',
            value: o.oldFingerprint,
          ),
          if (!o.isRevoke && o.newFingerprint.isNotEmpty) ...[
            const SizedBox(height: 10),
            _FingerprintRow(label: 'New key', value: o.newFingerprint),
          ],
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Icon(Icons.warning_amber_rounded, size: 20, color: Colors.orange),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Verify their identity out-of-band before applying. A '
                  'fingerprint you cannot confirm may signal an impersonation '
                  'attempt.',
                  style: TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(o.isRevoke ? 'Revoke' : 'Apply'),
        ),
      ],
    ),
  );
}

class _FingerprintRow extends StatelessWidget {
  const _FingerprintRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: 2),
        SelectableText(
          value.isEmpty ? '—' : value,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
      ],
    );
  }
}

/// Convenience for a sheet-local status dialog (used as [handleImportOutcome]'s
/// onStatus in settings flows). Swallows unmounted contexts.
Future<void> showImportStatus(BuildContext context, String message) {
  if (!context.mounted) return Future.value();
  return showMessageDialog(context, 'Contact Import', message);
}

/// maybeOfferCloudInvite completes the in-person exchange: after a brand-new
/// contact was added from a scanned QR or lock file, offer to send them a
/// cloud connect invite so they can accept and receive OUR lock back — no
/// second QR dance. Shown only when cloud is enabled AND signed in; silent
/// otherwise. Call after [handleImportOutcome] at every import site.
Future<void> maybeOfferCloudInvite(BuildContext context, ImportOutcome outcome) async {
  if (outcome.action != 0 || !outcome.applied || outcome.name.isEmpty) return;

  bool cloudReady;
  try {
    final st = jsonDecode(await cloudService.cloudUIState()) as Map<String, dynamic>;
    cloudReady = st['enabled'] == true && st['signed_in'] == true;
  } catch (_) {
    return; // cloud state unavailable — behave like cloud-off
  }
  if (!cloudReady || !context.mounted) return;

  final yes = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Invite ${outcome.name} to connect?'),
      content: Text(
        "${outcome.name}'s lock was added. Send a cloud invite so they can add "
        'your lock back — no need to scan a second QR.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('No'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Yes'),
        ),
      ],
    ),
  );
  if (yes != true || !context.mounted) return;

  try {
    await cloudService.inviteContact(outcome.name);
    if (!context.mounted) return;
    await showMessageDialog(context, 'Invite sent',
        '${outcome.name} can now accept and add your lock.');
  } catch (e) {
    if (!context.mounted) return;
    await showMessageDialog(context, 'Invite not sent', cleanBridgeError(e));
  }
}
