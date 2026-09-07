import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../bridge/bridge.gen.dart';
import '../bridge/filechooser.dart';
import 'settings_shared.dart';

class SettingsKeysTab extends StatelessWidget {
  const SettingsKeysTab({
    super.key,
    required this.identities,
    required this.hasKeys,
    required this.isLoading,
    required this.searchQuery,
    required this.onCreateKeys,
    required this.onRemoveIdentity,
    required this.onSetDefaultIdentity,
    required this.onRevokeIdentity,
    required this.onRotateIdentity,
    required this.onEditIdentity,
    required this.onToggleHWKey,
    required this.onImportIdentity,
    required this.onShowIdentity,
    required this.onExportLock,
    required this.onExportLockQR,
    required this.onExportIdentity,
    required this.onRefresh,
    required this.onError,
    required this.onStatus,
  });

  final List<Map<String, dynamic>> identities;
  final bool hasKeys;
  final bool isLoading;
  final String searchQuery;
  final Future<void> Function() onCreateKeys;
  final Future<void> Function(String name) onRemoveIdentity;
  final Future<void> Function(String name) onSetDefaultIdentity;
  final Future<void> Function(String name) onRevokeIdentity;
  final Future<void> Function(String name, String alias, String email, String firstName, String lastName) onRotateIdentity;
  final Future<void> Function(String name, String alias, String email, String firstName, String lastName) onEditIdentity;
  final Future<void> Function(String name, bool enable) onToggleHWKey;
  final Future<void> Function() onImportIdentity;
  final Future<String> Function(String name) onShowIdentity;
  final Future<String> Function(String name) onExportLock;
  final Future<String> Function(String name) onExportLockQR;
  final Future<void> Function(String name) onExportIdentity;
  final Future<void> Function() onRefresh;
  final void Function(String message) onError;
  final void Function(String message) onStatus;

  // _defaultFirst pins the default identity to the top of the list; every other
  // identity keeps its existing order (stable). So "Set as default" visibly
  // moves the chosen identity to the top.
  static List<Map<String, dynamic>> _defaultFirst(List<Map<String, dynamic>> ids) {
    final def = ids.where((i) => i['is_default'] == true);
    final rest = ids.where((i) => i['is_default'] != true);
    return [...def, ...rest];
  }

  void _showViewDialog(BuildContext context, String name, String json) {
    final id = jsonDecode(json) as Map<String, dynamic>;
    showDialog(
      context: context,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        return AlertDialog(
          title: Text(id['name'] as String? ?? name),
          content: Scrollbar(
            child: SingleChildScrollView(
              primary: true,
              padding: const EdgeInsets.only(right: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (id['is_primary'] == true)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Chip(
                        label: const Text('PRIMARY'),
                        backgroundColor: theme.colorScheme.primaryContainer,
                        labelStyle: TextStyle(color: theme.colorScheme.onPrimaryContainer),
                      ),
                    ),
                  detailRow('Alias', id['alias'] as String? ?? ''),
                  detailRow('First Name', id['first_name'] as String? ?? ''),
                  detailRow('Last Name', id['last_name'] as String? ?? ''),
                  detailRow('Email', id['email'] as String? ?? ''),
                  keyRow('Fingerprint', groupFingerprint(id['fingerprint'] as String? ?? ''), ctx),
                  CollapsibleKeyRow(label: 'Enc Lock', value: id['enc_pub_key'] as String? ?? ''),
                  CollapsibleKeyRow(label: 'Sign Lock', value: id['sign_pub_key'] as String? ?? ''),
                  detailRow('Created', id['created_at'] as String? ?? ''),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  void _showEditDialog(BuildContext context, Map<String, dynamic> id) {
    showDialog(
      context: context,
      builder: (_) => _EditIdentityDialog(
        identity: id,
        onSave: onEditIdentity,
        onError: onError,
        onRefresh: onRefresh,
      ),
    );
  }

  void _showRevokeDialog(BuildContext context, String name) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke Identity'),
        content: Text("Revoke identity '$name'? Keys will be retained for decrypting old files."),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                await onRevokeIdentity(name);
              } catch (e) {
                onError('Failed to revoke: $e');
              }
              await onRefresh();
            },
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
  }

  void _showRotateDialog(BuildContext context, Map<String, dynamic> id) {
    final name = id['name'] as String;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rotate Keys for $name'),
        content: const Text('Generate new keys? The old keys will be revoked but retained for decrypting old files.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                await onRotateIdentity(
                  name,
                  id['alias'] as String? ?? '',
                  id['email'] as String? ?? '',
                  id['first_name'] as String? ?? '',
                  id['last_name'] as String? ?? '',
                );
              } catch (e) {
                onError('Failed to rotate: $e');
              }
              await onRefresh();
            },
            child: const Text('Rotate'),
          ),
        ],
      ),
    );
  }

  // _showHWToggleDialog confirms enabling or disabling hardware-key
  // protection on an existing identity. Both directions re-encrypt the
  // stored keys (enable: under HW-augmented KEK; disable: under
  // passphrase-only KEK), so the user is warned that the device may need
  // to be touched. The backend handles the actual re-encryption +
  // rollback.
  void _showHWToggleDialog(BuildContext context, String name, {required bool enable}) {
    final title = enable ? 'Enable Hardware Key' : 'Disable Hardware Key';
    final body = enable
        ? "Re-encrypt $name's keys with a hardware key as the 2nd factor.\n\n"
              'Slot 2 of the hardware key must already be programmed for '
              'HMAC-SHA1 challenge-response (via ykman or KeePassXC). The '
              'device may need to be touched during setup.'
        : "Re-encrypt $name's keys without hardware-key protection.\n\n"
              'The device may need to be touched once to read the existing '
              'keys before re-encryption.';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                await onToggleHWKey(name, enable);
              } catch (e) {
                onError(enable ? 'Failed to enable hardware key: $e' : 'Failed to disable hardware key: $e');
              }
              await onRefresh();
            },
            child: Text(enable ? 'Enable' : 'Disable'),
          ),
        ],
      ),
    );
  }

  void _showRemoveDialog(BuildContext context, String name) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Remove Identity'),
          content: Text("Are you sure you want to remove identity '$name'?"),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                unawaited(showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (_) => const PopScope(
                    canPop: false,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ));
                try {
                  await onRemoveIdentity(name);
                } catch (e) {
                  onError('Failed to remove identity: $e');
                }
                await onRefresh();
                if (context.mounted) Navigator.of(context).pop();
              },
              child: const Text('Remove'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showExportMenu(BuildContext context, String name) async {
    final theme = Theme.of(context);
    // Cloud directory entries (publish/unpublish) live here — publishing IS
    // sharing your lock. Shown only when cloud is on AND signed in. The
    // published/unpublished hint matches the account's directory rows by
    // display name (no identity unlock just to render a menu); a failed
    // state lookup degrades to offering Publish — an idempotent upsert.
    var cloudReady = false;
    var published = false;
    try {
      final st = jsonDecode(await cloudService.cloudUIState()) as Map<String, dynamic>;
      cloudReady = st['enabled'] == true && st['signed_in'] == true;
    } catch (_) {
      // Cloud state unavailable: hide the entries.
    }
    if (cloudReady) {
      try {
        final rows = (jsonDecode(await cloudService.publishedDirectory()) as List<dynamic>)
            .cast<Map<String, dynamic>>();
        published = rows.any((r) => r['display_name'] == name);
      } catch (_) {
        published = false; // unknown state → offer Publish
      }
    }
    if (!context.mounted) return;
    unawaited(showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHigh,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              width: 32,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('Share Lock', style: theme.textTheme.titleMedium),
            ),
            buildActionTile(ctx, theme, Icons.save_alt, 'Export to File', 'Save encrypted lock to disk', () {
              Navigator.pop(ctx);
              _exportToFile(context, name);
            }),
            const SizedBox(height: 8),
            buildActionTile(ctx, theme, Icons.qr_code, 'QR Code', 'Display scannable QR code', () {
              Navigator.pop(ctx);
              _showQRDialog(context, name);
            }),
            if (cloudReady) const SizedBox(height: 8),
            if (cloudReady && !published)
              buildActionTile(ctx, theme, Icons.cloud_upload_outlined, 'Publish to Cloud Directory', 'Others can find this identity by name, alias, or email', () {
                Navigator.pop(ctx);
                _confirmPublish(context, name, publish: true);
              }),
            if (cloudReady && published)
              buildActionTile(ctx, theme, Icons.cloud_off_outlined, 'Unpublish from Cloud Directory', 'Published — remove it from cloud search', () {
                Navigator.pop(ctx);
                _confirmPublish(context, name, publish: false);
              }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ));
  }

  void _confirmPublish(BuildContext context, String name, {required bool publish}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(publish ? 'Publish "$name"?' : 'Unpublish "$name"?'),
        content: Text(publish
            ? 'The identity\'s lock (public key) becomes searchable in the cloud directory by name, alias, or email. You can unpublish at any time.'
            : 'The identity is removed from cloud search. People who already saved its lock keep it.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                if (publish) {
                  await cloudService.publishIdentity(name);
                  onStatus('Published "$name" to the cloud directory');
                  return;
                }
                await cloudService.unpublishIdentity(name);
                onStatus('Unpublished "$name" from the cloud directory');
              } catch (e) {
                onError(publish ? 'Publish failed: $e' : 'Unpublish failed: $e');
              }
            },
            child: Text(publish ? 'Publish' : 'Unpublish'),
          ),
        ],
      ),
    );
  }

  void _showMoreMenu(BuildContext context, Map<String, dynamic> id) {
    final theme = Theme.of(context);
    final name = id['name'] as String;
    final hwOn = id['hw_key'] == true;
    // Revocation status lives in the encrypted meta and isn't available
    // here without an unlock, so the list-view menu shows all options
    // and lets the backend reject inapplicable ones (e.g. revoking an
    // already-revoked identity returns a clear error message).

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  width: 32,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('More Options', style: theme.textTheme.titleMedium),
                ),
            buildActionTile(ctx, theme, Icons.edit, 'Edit', '', () {
              Navigator.pop(ctx);
              _showEditDialog(context, id);
            }),
            if (id['is_default'] != true) ...[
              const SizedBox(height: 8),
              buildActionTile(ctx, theme, Icons.star_outline, 'Set as default',
                  'Re-keys cloud data to this identity', () {
                Navigator.pop(ctx);
                onSetDefaultIdentity(name);
              }),
            ],
            const SizedBox(height: 8),
            buildActionTile(ctx, theme, Icons.refresh, 'Rotate Keys', '', () {
              Navigator.pop(ctx);
              _showRotateDialog(context, id);
            }),
            const SizedBox(height: 8),
            if (hwOn)
              buildActionTile(ctx, theme, Icons.usb_off, 'Disable hardware key', 'Re-encrypt without HW', () {
                Navigator.pop(ctx);
                _showHWToggleDialog(context, name, enable: false);
              })
            else
              buildActionTile(ctx, theme, Icons.usb, 'Enable hardware key', 'Yubikey, NitroKey, OnlyKey', () {
                Navigator.pop(ctx);
                _showHWToggleDialog(context, name, enable: true);
              }),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            buildActionTile(ctx, theme, Icons.backup, 'Backup Identity', 'Key + Lock', () {
              Navigator.pop(ctx);
              onExportIdentity(name);
            }),
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 8),
            buildActionTile(ctx, theme, Icons.block, 'Revoke', '', () {
              Navigator.pop(ctx);
              _showRevokeDialog(context, name);
            }, color: theme.colorScheme.error),
            const SizedBox(height: 8),
            buildActionTile(ctx, theme, Icons.delete_outline, 'Remove', '', () {
              Navigator.pop(ctx);
              _showRemoveDialog(context, name);
            }, color: theme.colorScheme.error),
            const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _exportToFile(BuildContext context, String name) async {
    try {
      final armored = await onExportLock(name);
      if (!context.mounted) return;

      final result = await fileChooserService.saveFile(
        'Export Lock',
        '$name.lock',
        '',
        bytes: Uint8List.fromList(armored.codeUnits),
      );
      if (result.cancelled || !context.mounted) return;
      onStatus('Lock exported to ${result.savedPath}');
    } catch (e) {
      if (!context.mounted) return;
      onError('Export failed: $e');
    }
  }

  Future<void> _showQRDialog(BuildContext context, String name) {
    // Opens immediately with a loading state; errors render in the dialog.
    return showLockQRDialog(
      context,
      title: name,
      saveBaseName: '$name-qr',
      export: () => onExportLockQR(name),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buttonStyle = OutlinedButton.styleFrom(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasKeys && identities.isNotEmpty) ...[
          ..._defaultFirst(identities).map((id) {
            final name = id['name'] as String;
            final isDefault = id['is_default'] == true;
            final hwKey = id['hw_key'] == true;
            final backend = id['backend'] as String? ?? '';
            // status (active/revoked) is encrypted meta — only available
            // after ShowIdentity unlock. The list view shows just the
            // backend-level info; revoked state is shown in the detail
            // dialog and inferred lazily by the more-options menu.
            return ListTile(
              dense: true,
              leading: const Icon(Icons.vpn_key, size: 20),
              title: Row(
                children: [
                  Text(name),
                  if (isDefault) ...[
                    const SizedBox(width: 8),
                    Chip(
                      label: const Text('default'),
                      labelStyle: theme.textTheme.labelSmall,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ],
                  if (hwKey) ...[
                    const SizedBox(width: 8),
                    Chip(
                      label: const Text('hw'),
                      labelStyle: theme.textTheme.labelSmall,
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ],
                ],
              ),
              subtitle: backend.isNotEmpty
                  ? Text(backend, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant))
                  : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ViewIconButton(
                    name: name,
                    onShowIdentity: onShowIdentity,
                    showViewDialog: _showViewDialog,
                  ),
                  IconButton(
                    icon: const Icon(Icons.share, size: 20),
                    tooltip: 'Share Lock (public key)',
                    onPressed: () => _showExportMenu(context, name),
                  ),
                  IconButton(
                    icon: const Icon(Icons.more_vert, size: 20),
                    tooltip: 'More options',
                    onPressed: () => _showMoreMenu(context, id),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 8),
        ],
        if (hasKeys && identities.isEmpty && searchQuery.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No matching identities',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: isLoading ? null : () async {
                  unawaited(showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => const PopScope(
                      canPop: false,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ));
                  try {
                    await onCreateKeys();
                    await onRefresh();
                  } catch (e) {
                    onError('Failed to create keys: $e');
                  } finally {
                    if (context.mounted) Navigator.of(context).pop();
                  }
                },
                style: buttonStyle,
                icon: const Icon(Icons.lock_open),
                label: const Text('Create Identity'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: isLoading ? null : () async {
                  // _importIdentity owns the multi-step UX (file picker,
                  // passphrase dialog, conflict/HW dialogs) and toggles its
                  // own _isLoading. We add a barrier-spinner that sits
                  // BENEATH those dialogs so the user sees activity
                  // feedback during the actual work phases (peek + import).
                  unawaited(showDialog(
                    context: context,
                    barrierDismissible: false,
                    builder: (_) => const PopScope(
                      canPop: false,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ));
                  try {
                    await onImportIdentity();
                    await onRefresh();
                  } finally {
                    if (context.mounted) Navigator.of(context).pop();
                  }
                },
                style: buttonStyle,
                icon: const Icon(Icons.download),
                label: const Text('Import Identity'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ViewIconButton extends StatefulWidget {
  const _ViewIconButton({
    required this.name,
    required this.onShowIdentity,
    required this.showViewDialog,
  });

  final String name;
  final Future<String> Function(String name) onShowIdentity;
  final void Function(BuildContext context, String name, String json) showViewDialog;

  @override
  State<_ViewIconButton> createState() => _ViewIconButtonState();
}

class _ViewIconButtonState extends State<_ViewIconButton> {
  var _isLoading = false;

  Future<void> _handleTap() async {
    setState(() => _isLoading = true);
    try {
      final json = await widget.onShowIdentity(widget.name);
      if (!mounted || json.isEmpty) return;
      widget.showViewDialog(context, widget.name, json);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const IconButton(
        icon: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        tooltip: 'Loading…',
        onPressed: null,
      );
    }
    return IconButton(
      icon: const Icon(Icons.visibility, size: 20),
      tooltip: 'View details',
      onPressed: _handleTap,
    );
  }
}

class _EditIdentityDialog extends StatefulWidget {
  final Map<String, dynamic> identity;
  final Future<void> Function(String name, String alias, String email, String firstName, String lastName) onSave;
  final void Function(String message) onError;
  final Future<void> Function() onRefresh;

  const _EditIdentityDialog({
    required this.identity,
    required this.onSave,
    required this.onError,
    required this.onRefresh,
  });

  @override
  State<_EditIdentityDialog> createState() => _EditIdentityDialogState();
}

class _EditIdentityDialogState extends State<_EditIdentityDialog> {
  late final TextEditingController _aliasCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _firstNameCtrl;
  late final TextEditingController _lastNameCtrl;

  @override
  void initState() {
    super.initState();
    _aliasCtrl = TextEditingController(text: widget.identity['alias'] as String? ?? '');
    _emailCtrl = TextEditingController(text: widget.identity['email'] as String? ?? '');
    _firstNameCtrl = TextEditingController(text: widget.identity['first_name'] as String? ?? '');
    _lastNameCtrl = TextEditingController(text: widget.identity['last_name'] as String? ?? '');
  }

  @override
  void dispose() {
    _aliasCtrl.dispose();
    _emailCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.identity['name'] as String;
    return AlertDialog(
      title: Text('Edit $name'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Name is the identity's stable key — shown as a read-only
            // display so the user knows which one they're editing. Plain
            // Text instead of TextField since it's never editable.
            InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
              child: Text(name),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _aliasCtrl,
              autofocus: true,
              inputFormatters: aliasInputFormatters,
              decoration: const InputDecoration(
                labelText: 'Alias',
                helperText: 'Single word: a-z, 0-9, - and _',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emailCtrl,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _firstNameCtrl,
              decoration: const InputDecoration(
                labelText: 'First Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _lastNameCtrl,
              decoration: const InputDecoration(
                labelText: 'Last Name',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.of(context).pop();
            try {
              await widget.onSave(
                name,
                _aliasCtrl.text,
                _emailCtrl.text,
                _firstNameCtrl.text,
                _lastNameCtrl.text,
              );
            } catch (e) {
              widget.onError('Failed to update identity: $e');
            }
            await widget.onRefresh();
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
