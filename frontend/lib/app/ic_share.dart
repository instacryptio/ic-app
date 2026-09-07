/// IC Share: upload an already-encrypted .icfx to Instacrypt Cloud,
/// addressed to the contact it was encrypted for. Entry point is
/// [runICShareFlow] (options dialog → upload → result dialog); the sheet in
/// the Cloud tab reuses the formatting helpers.
///
/// Follows the dialogs.dart contract: context + data in, Future out, no
/// HomePage state touched.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../bridge/bridge.gen.dart';

/// runICShareFlow drives the whole flow from the success dialog's IC Share
/// button: expiry/single-use options → upload → link dialog. [recipients] is
/// the SAME set the file was encrypted to (contact aliases and/or group names);
/// [alsoSelf] additionally shares to the account's other devices. An empty
/// [recipients] with [alsoSelf] is a pure SELF-share (no e-mail, no fingerprint
/// sent).
Future<void> runICShareFlow(
  BuildContext context, {
  required String filePath,
  required List<String> recipients,
  required bool alsoSelf,
}) async {
  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => _ICShareOptionsDialog(
      filePath: filePath,
      recipients: recipients,
      alsoSelf: alsoSelf,
    ),
  );
  if (result == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => _ICShareResultDialog(
      recipients: recipients,
      alsoSelf: alsoSelf,
      noMail: result['no_mail'] == true,
      warnings: (result['warnings'] as List?)?.cast<String>() ?? const [],
    ),
  );
}

class _ICShareOptionsDialog extends StatefulWidget {
  const _ICShareOptionsDialog({
    required this.filePath,
    required this.recipients,
    required this.alsoSelf,
  });

  final String filePath;
  final List<String> recipients;
  final bool alsoSelf;

  @override
  State<_ICShareOptionsDialog> createState() => _ICShareOptionsDialogState();
}

class _ICShareOptionsDialogState extends State<_ICShareOptionsDialog> {
  static const _expiryChoices = <int, String>{
    86400: '1 day',
    604800: '7 days',
    2592000: '30 days',
    0: 'Never — kept until deleted',
  };

  int _ttlSeconds = 604800;
  bool _singleUse = false;
  bool _noMail = false;
  bool _busy = false;
  double? _progress; // upload fraction (0..1); null before the first event
  String? _error;
  Future<void> _share() async {
    setState(() {
      _busy = true;
      _progress = null; // indeterminate spin until the first real upload value
      _error = null;
    });
    try {
      // Stream the send so the button shows a determinate upload fill.
      var raw = '';
      await for (final p in cloudService.shareEncryptedFileStream(
        widget.filePath,
        widget.recipients,
        widget.alsoSelf,
        _ttlSeconds,
        _singleUse,
        _noMail,
      )) {
        if (!mounted) return;
        if (p.phase == 'done') raw = p.result;
        setState(() => _progress = p.pct);
      }
      if (!mounted) return;
      final res = jsonDecode(raw) as Map<String, dynamic>;
      res['no_mail'] = _noMail;
      Navigator.of(context).pop(res);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _progress = null;
        _error = cleanBridgeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fileName = widget.filePath.split(Platform.pathSeparator).last;
    final selfOnly = widget.recipients.isEmpty;
    return AlertDialog(
      title: const Text('IC Share'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_shareSummary(fileName, widget.recipients, widget.alsoSelf)),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text('Expires: '),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButton<int>(
                  value: _ttlSeconds,
                  isExpanded: true,
                  items: [
                    for (final e in _expiryChoices.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: _busy ? null : (v) => setState(() => _ttlSeconds = v ?? _ttlSeconds),
                ),
              ),
            ],
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: const Text('Single-use (one download)'),
            value: _singleUse,
            onChanged: _busy ? null : (v) => setState(() => _singleUse = v ?? false),
          ),
          // Self-shares have no e-mail — the toggle only applies to contacts.
          if (!selfOnly)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text("Don't notify by e-mail"),
              subtitle: const Text('They still see it in their app'),
              value: _noMail,
              onChanged: _busy ? null : (v) => setState(() => _noMail = v ?? false),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _share,
          child: _busy
              ? SizedBox(
                  width: 18,
                  height: 18,
                  child: animatedProgressIndicator(_progress),
                )
              : const Text('Share'),
        ),
      ],
    );
  }
}

/// _shareSummary describes who a share goes to: "Send X to your other devices"
/// for a pure self-share, otherwise "Share X with ..." naming the recipients,
/// plus a trailing ", and your other devices" when the file was also encrypted
/// to self.
String _shareSummary(String fileName, List<String> recipients, bool alsoSelf) {
  if (recipients.isEmpty) return 'Send $fileName to your other devices';
  final who = recipients.join(', ') + (alsoSelf ? ', and your other devices' : '');
  return 'Share $fileName with $who';
}

class _ICShareResultDialog extends StatelessWidget {
  const _ICShareResultDialog({
    required this.recipients,
    required this.alsoSelf,
    required this.noMail,
    required this.warnings,
  });

  final List<String> recipients;
  final bool alsoSelf;
  final bool noMail;
  final List<String> warnings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Shared'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_deliveryMessage()),
          for (final w in warnings)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 18, color: theme.colorScheme.tertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(w,
                        style: TextStyle(color: theme.colorScheme.tertiary)),
                  ),
                ],
              ),
            ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }

  String _deliveryMessage() {
    if (recipients.isEmpty) {
      return 'Sent to your other devices.\n\n'
          'Open the notification bell on another signed-in device to receive it.';
    }
    final who = recipients.join(', ');
    final delivery = noMail
        ? 'They will see it in their Instacrypt notifications.'
        : 'They were notified by e-mail and will also see it in their Instacrypt notifications.';
    final self = alsoSelf ? ' It was also sent to your other devices.' : '';
    return 'Shared with $who.$self\n\n$delivery';
  }
}

/// cleanBridgeError strips the Go error-chain prefixes the bridge surfaces
/// (mirrors the trimming _submit does for status lines).
String cleanBridgeError(Object e) {
  final segments = e.toString().split(': ');
  if (segments.length > 2) {
    return segments.sublist(segments.length - 2).join(': ');
  }
  return segments.last;
}

/// animatedProgressIndicator spins (indeterminate) while [progress] is null, then
/// shows a determinate circle that smoothly animates to each new value — so
/// fast/bursty streamed progress still renders a visible fill instead of a blank
/// circle that jumps to done. Shared by the send button and the receive row.
Widget animatedProgressIndicator(double? progress) {
  if (progress == null) {
    return const CircularProgressIndicator(strokeWidth: 2);
  }
  return TweenAnimationBuilder<double>(
    tween: Tween<double>(begin: 0, end: progress),
    duration: const Duration(milliseconds: 250),
    curve: Curves.easeOut,
    builder: (_, value, __) =>
        CircularProgressIndicator(strokeWidth: 2, value: value),
  );
}

/// icShareHumanSize renders a byte count for share rows and dialogs.
String icShareHumanSize(int b) {
  if (b >= 1 << 30) return '${(b / (1 << 30)).toStringAsFixed(2)} GiB';
  if (b >= 1 << 20) return '${(b / (1 << 20)).toStringAsFixed(2)} MiB';
  if (b >= 1 << 10) return '${(b / (1 << 10)).toStringAsFixed(2)} KiB';
  return '$b B';
}

/// icShareExpiryLabel renders a share's expiry: "expires in 6d", "expires in
/// 3h", "expired", or "never expires" for an empty RFC3339 string.
String icShareExpiryLabel(String rfc3339) {
  if (rfc3339.isEmpty) return 'never expires';
  final t = DateTime.tryParse(rfc3339);
  if (t == null) return 'never expires';
  final left = t.difference(DateTime.now());
  if (left.isNegative) return 'expired';
  if (left.inDays >= 1) return 'expires in ${left.inDays}d';
  if (left.inHours >= 1) return 'expires in ${left.inHours}h';
  return 'expires in ${left.inMinutes}m';
}
