/// Cloud notification drawer: the bell's sub-drawer listing ALL cloud
/// notices as history — incoming shares (with in-place decrypt), contact
/// invites, and drain events (accepted/rotated/revoked). Rows persist until
/// the user deletes them.
///
/// Follows the dialogs.dart contract: context + callbacks in, no HomePage
/// state touched. All errors render inline in the drawer.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../bridge/bridge.gen.dart';
import '../bridge/filechooser.dart';
import 'dialogs.dart';
import 'hw_flow.dart' show hwRequiredIdentityFrom, prepareHWForIdentity;
import 'ic_share.dart'
    show
        animatedProgressIndicator,
        cleanBridgeError,
        icShareExpiryLabel,
        icShareHumanSize;
import 'top_drawer.dart';
import 'unlock_flow.dart';

/// showCloudNotificationsDrawer opens the bell drawer. onOpenContacts is
/// invoked when the user taps View on a contact invite (the caller closes
/// this drawer and navigates to the Contacts tab).
Future<void> showCloudNotificationsDrawer(
  BuildContext context, {
  required void Function() onOpenContacts,
}) {
  return showTopDrawer<void>(
    context,
    builder: (_) => _NotificationsDrawer(onOpenContacts: onOpenContacts),
  );
}

class _NotificationsDrawer extends StatefulWidget {
  const _NotificationsDrawer({required this.onOpenContacts});

  final void Function() onOpenContacts;

  @override
  State<_NotificationsDrawer> createState() => _NotificationsDrawerState();
}

class _NotificationsDrawerState extends State<_NotificationsDrawer> {
  List<Map<String, dynamic>>? _items;
  String? _error;
  String? _busyID; // notification being decrypted or deleted
  double? _progress; // download fraction (0..1) for the busy row; null = indeterminate

  @override
  void initState() {
    super.initState();
    _load(markSeen: true);
  }

  Future<void> _load({bool markSeen = false}) async {
    try {
      final raw = jsonDecode(await cloudService.cloudNotices()) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _items = ((raw['notifications'] as List<dynamic>?) ?? [])
            .cast<Map<String, dynamic>>();
        _error = null;
      });
      if (markSeen) {
        // Badge clears; rows keep their unseen highlight until reload.
        await cloudService.markNotificationsSeen();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items = _items ?? [];
        _error = cleanBridgeError(e);
      });
    }
  }

  Future<void> _delete(String id) async {
    setState(() => _busyID = id);
    try {
      await cloudService.deleteNotification(id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = cleanBridgeError(e));
    } finally {
      if (mounted) {
        setState(() {
          _busyID = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _decrypt(Map<String, dynamic> item,
      {bool force = false, bool hwRetried = false}) async {
    final shareID = (item['share_id'] as String?) ?? '';
    final id = (item['id'] as String?) ?? '';

    // Locked app? Prompt the unlock ceremony up front (same shared code
    // path as the home screen) instead of failing mid-decrypt.
    final unlocked = await ensureSessionUnlocked(context,
        onError: (m) => setState(() => _error = m));
    if (!unlocked || !mounted) return;

    // Desktop chooses the destination up front (XDG portal on Linux); on
    // mobile the SAF save dialog is the chooser, so no directory pick here.
    // Inside a try: an uncaught bridge error here would vanish into the
    // async zone and the button would just look dead.
    var destDir = '';
    final isMobile = Platform.isAndroid || Platform.isIOS;
    if (!isMobile) {
      try {
        final picked = await fileChooserService.pickDirectory('Save Shared File To…');
        if (picked == null || picked.isEmpty) return; // cancelled
        destDir = picked;
      } catch (e) {
        if (!mounted) return;
        setState(() => _error = cleanBridgeError(e));
        return;
      }
    }
    if (!mounted) return;

    setState(() {
      _busyID = id;
      _progress = null; // indeterminate spin until the first real progress value
      _error = null;
    });
    try {
      // Stream the receive: one continuous fill covering download (first half)
      // then decrypt (second half). The terminal "done" event carries the same
      // JSON ReceiveShare returns, so the rest of the flow is unchanged.
      var raw = '';
      await for (final p in cloudService.receiveShareStream(shareID, destDir, force)) {
        if (!mounted) return;
        if (p.phase == 'done') {
          raw = p.result;
        }
        setState(() => _progress = p.pct);
      }
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final fileName = (decoded['file_name'] as String?) ?? 'file';
      if (!mounted) return;

      final result = await fileChooserService.handleWriteResult(raw, fileName);
      if (result.exists) {
        if (!mounted) return;
        setState(() => _busyID = null);
        final confirmed = await showOverwriteConfirmDialog(context, result.savedPath!);
        if (!confirmed || !mounted) return;
        await _decrypt(item, force: true);
        return;
      }
      if (result.cancelled || !mounted) return;
      if (result.error != null) {
        setState(() => _error = result.error);
        return;
      }

      var message = 'Decrypted $fileName';
      final sender = (decoded['sender'] as String?) ?? '';
      if (sender.isNotEmpty) message += '\nfrom $sender';
      final verifyMsg = (decoded['verify_msg'] as String?) ?? '';
      if (verifyMsg.isNotEmpty) message += '\n$verifyMsg';

      await _load(); // row flips to handled
      if (!mounted) return;
      showSuccessDialog(context, message, result);
    } catch (e) {
      if (!mounted) return;
      // The identity needs a staged hardware-key tap (auto-lock wiped the
      // response, or the share targets a non-default identity): run the
      // tap flow and retry once — same pattern as the sync flow.
      final hwIdentity = hwRequiredIdentityFrom(e.toString());
      if (hwIdentity != null && !hwRetried) {
        setState(() => _busyID = null);
        final ready = await prepareHWForIdentity(context, hwIdentity);
        if (ready && mounted) {
          await _decrypt(item, force: force, hwRetried: true);
        }
        return;
      }
      setState(() => _error = cleanBridgeError(e));
    } finally {
      if (mounted) {
        setState(() {
          _busyID = null;
          _progress = null;
        });
      }
    }
  }

  String _title(Map<String, dynamic> n) {
    final alias = (n['alias'] as String?) ?? '';
    switch ((n['kind'] as String?) ?? '') {
      case 'share':
        final sender = (n['sender'] as String?) ?? 'Someone';
        // Self-shares (backend labels the sender "My devices").
        if (sender == 'My devices') return 'File from your devices';
        return '$sender shared a file';
      case 'invite':
        return 'New contact request';
      case 'accepted':
        return '$alias accepted your contact request';
      case 'rotated':
        return '$alias rotated their keys — new lock applied';
      case 'revoked':
        return '$alias revoked their key';
      default:
        return 'Cloud notice';
    }
  }

  IconData _icon(String kind) {
    switch (kind) {
      case 'share':
        return Icons.download_outlined;
      case 'invite':
        return Icons.person_add_alt;
      case 'revoked':
        return Icons.key_off_outlined;
      default:
        return Icons.info_outline;
    }
  }

  Widget _row(BuildContext context, Map<String, dynamic> n) {
    final theme = Theme.of(context);
    final kind = (n['kind'] as String?) ?? '';
    final id = (n['id'] as String?) ?? '';
    final handled = n['handled'] == true;
    final busy = _busyID == id;

    final singleUse = n['single_use'] == true;
    final retired = n['retired'] == true;
    final expiresAt = (n['expires_at'] as String?) ?? '';
    final expired = expiresAt.isNotEmpty &&
        (DateTime.tryParse(expiresAt)?.isBefore(DateTime.now()) ?? false);

    String? subtitle;
    if (kind == 'share') {
      final parts = <String>[
        (n['file_name'] as String?) ?? '',
        icShareHumanSize((n['file_size'] as num?)?.toInt() ?? 0),
        icShareExpiryLabel(expiresAt),
      ];
      if (singleUse) parts.insert(2, 'single-use');
      if (handled) parts.add('decrypted');
      subtitle = parts.where((p) => p.isNotEmpty).join(' · ');
    }

    final actions = <Widget>[];
    // Decrypt stays available for the share's whole life on EVERY device
    // (re-downloads are fine server-side). It goes away only when the share
    // can truly never be downloaded again: retired (consumed single-use /
    // cancelled / expired, learned from the inbox poll), locally consumed
    // single-use, or past its expiry.
    final decryptable =
        kind == 'share' && !retired && !expired && !(handled && singleUse);
    if (decryptable) {
      actions.add(busy
          ? SizedBox(
              width: 20,
              height: 20,
              // One continuous fill across download + decrypt, driven by the
              // receive progress stream (_progress, 0..1).
              child: animatedProgressIndicator(_progress),
            )
          : TextButton(
              onPressed: _busyID != null ? null : () => _decrypt(n),
              child: const Text('Decrypt'),
            ));
    }
    // Mutually exclusive with the block above (an expired/retired share is never
    // decryptable): say the share is gone so the row isn't just a Decrypt button
    // silently missing.
    if (kind == 'share' && (expired || retired)) {
      actions.add(Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          expired ? 'Expired' : 'Removed',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ));
    }
    if (kind == 'invite') {
      actions.add(TextButton(
        onPressed: widget.onOpenContacts,
        child: const Text('View'),
      ));
    }
    if (kind != 'invite') {
      actions.add(busy && kind != 'share'
          ? const SizedBox(
              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : IconButton(
              // Dismiss only clears the local notification — it does NOT delete
              // the shared file. A distinct icon (vs the trash in Manage Shared
              // Files) so users don't conflate the two.
              icon: const Icon(Icons.close, size: 20),
              tooltip: 'Dismiss notification',
              onPressed: _busyID != null ? null : () => _delete(id),
            ));
    }

    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(_icon(kind),
          color: n['seen'] == true ? null : theme.colorScheme.primary),
      title: Text(_title(n)),
      subtitle: subtitle != null ? Text(subtitle) : null,
      trailing: Row(mainAxisSize: MainAxisSize.min, children: actions),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Cloud Notifications', style: theme.textTheme.titleMedium),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ),
              const SizedBox(height: 8),
              if (_items == null)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                )
              else if (_items!.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'No notifications.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _items!.length,
                    itemBuilder: (ctx, i) => _row(ctx, _items![i]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
