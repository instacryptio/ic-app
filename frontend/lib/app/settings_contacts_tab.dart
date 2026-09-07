import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../bridge/bridge.gen.dart';
import '../bridge/filechooser.dart';
import 'dialogs.dart' show showSearchCloudDialog;
import 'ic_share.dart' show cleanBridgeError;
import 'import_confirm.dart';
import 'settings_shared.dart';

/// Result from importing one scanned animated QR frame.
/// [received]/[total] drive the scanner's progress display. Once [complete],
/// [outcome] carries the parsed import result (applied, or needing confirmation).
class QRPartResult {
  final bool complete;
  final int received;
  final int total;
  final ImportOutcome? outcome;
  QRPartResult({required this.complete, this.received = 0, this.total = 0, this.outcome});
}

class SettingsContactsTab extends StatelessWidget {
  const SettingsContactsTab({
    super.key,
    required this.contacts,
    required this.hasKeys,
    required this.isLoading,
    required this.searchQuery,
    required this.onAddContact,
    required this.onRemoveContact,
    required this.onEditContact,
    required this.onShowContact,
    required this.onExportContactLock,
    required this.onExportContactLockQR,
    required this.onImportLockFile,
    required this.onImportLockQR,
    required this.onImportLockQRPart,
    required this.onConfirmContactImport,
    required this.onRefresh,
    required this.onError,
    required this.onStatus,
    required this.cloudReady,
  });

  final List<Map<String, dynamic>> contacts;
  final bool hasKeys;
  final bool isLoading;
  final String searchQuery;
  final Future<void> Function(String alias, String nickname, String firstName, String lastName, String email, String encPubKey, String signPubKey, String fingerprint) onAddContact;
  final Future<void> Function(String alias) onRemoveContact;
  final Future<void> Function(String alias, String nickname, String firstName, String lastName, String email, String encPubKey, String signPubKey, String fingerprint) onEditContact;
  final Future<String> Function(String alias) onShowContact;
  final Future<String> Function(String alias) onExportContactLock;
  final Future<String> Function(String alias) onExportContactLockQR;
  final Future<ImportOutcome> Function(String path, String alias) onImportLockFile;
  final Future<void> Function(String qrData, String alias) onImportLockQR;
  final Future<QRPartResult> Function(String partJSON, String alias) onImportLockQRPart;
  final Future<void> Function(String token) onConfirmContactImport;
  final Future<void> Function() onRefresh;
  final void Function(String message) onError;
  final void Function(String message) onStatus;

  /// Cloud enabled + signed in — shows the per-contact connection icons.
  final bool cloudReady;

  bool get _isDesktopPlatform => Platform.isLinux || Platform.isMacOS || Platform.isWindows;

  void _showViewDialog(BuildContext context, String alias, String json) {
    final c = jsonDecode(json) as Map<String, dynamic>;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(c['alias'] as String? ?? alias),
        content: Scrollbar(
          child: SingleChildScrollView(
            primary: true,
            padding: const EdgeInsets.only(right: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                detailRow('Alias', c['alias'] as String? ?? ''),
                detailRow('Nickname', c['nickname'] as String? ?? ''),
                detailRow('First Name', c['first_name'] as String? ?? ''),
                detailRow('Last Name', c['last_name'] as String? ?? ''),
                detailRow('Email', c['email'] as String? ?? ''),
                keyRow('Fingerprint', groupFingerprint(c['fingerprint'] as String? ?? ''), ctx),
                CollapsibleKeyRow(label: 'Enc Lock', value: c['enc_pub_key'] as String? ?? ''),
                CollapsibleKeyRow(label: 'Sign Lock', value: c['sign_pub_key'] as String? ?? ''),
                detailRow('Added', c['added_at'] as String? ?? ''),
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
      ),
    );
  }

  void _showEditDialog(BuildContext context, String alias, String json) {
    showDialog(
      context: context,
      builder: (_) => _EditContactDialog(
        alias: alias,
        contactJson: json,
        onSave: onEditContact,
        onError: onError,
        onRefresh: onRefresh,
      ),
    );
  }

  void _showRemoveDialog(BuildContext context, String alias) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Contact'),
        content: Text("Are you sure you want to remove contact '$alias'?"),
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
                await onRemoveContact(alias);
              } catch (e) {
                onError('Failed to remove contact: $e');
              }
              await onRefresh();
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  void _showExportMenu(BuildContext context, String alias) {
    final theme = Theme.of(context);
    showModalBottomSheet(
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
            buildActionTile(ctx, theme, Icons.save_alt, 'Export to File', 'Save contact lock to disk', () {
              Navigator.pop(ctx);
              _exportToFile(context, alias);
            }),
            const SizedBox(height: 8),
            buildActionTile(ctx, theme, Icons.qr_code, 'QR Code', 'Display scannable QR code', () {
              Navigator.pop(ctx);
              _showQRDialog(context, alias);
            }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _exportToFile(BuildContext context, String alias) async {
    try {
      final armored = await onExportContactLock(alias);
      if (!context.mounted) return;

      final result = await fileChooserService.saveFile(
        'Export Lock',
        '$alias.lock',
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

  Future<void> _showQRDialog(BuildContext context, String alias) {
    // Opens immediately with a loading state; errors render in the dialog.
    return showLockQRDialog(
      context,
      title: alias,
      saveBaseName: '$alias-qr',
      export: () => onExportContactLockQR(alias),
    );
  }

  Future<void> _showAddContactSheet(BuildContext context) async {
    final theme = Theme.of(context);
    // Cloud discovery is only offered when cloud is on AND signed in.
    var cloudReady = false;
    try {
      final st = jsonDecode(await cloudService.cloudUIState()) as Map<String, dynamic>;
      cloudReady = st['enabled'] == true && st['signed_in'] == true;
    } catch (_) {
      // Offline/misconfigured cloud just hides the tile.
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
              child: Text('Add Contact', style: theme.textTheme.titleMedium),
            ),
            buildActionTile(ctx, theme, Icons.edit, 'Manual', 'Enter contact details manually', () {
              Navigator.pop(ctx);
              _showManualContactDialog(context);
            }),
            const SizedBox(height: 8),
            buildActionTile(ctx, theme, Icons.file_open, 'Import Lock', 'Import from a lock file', () {
              Navigator.pop(ctx);
              _importLockFlow(context);
            }),
            const SizedBox(height: 8),
            if (!_isDesktopPlatform)
              buildActionTile(ctx, theme, Icons.qr_code_scanner, 'Scan QR Code', 'Scan QR code to import contact', () {
                Navigator.pop(ctx);
                _scanQRFlow(context);
              }),
            if (!_isDesktopPlatform) const SizedBox(height: 8),
            if (cloudReady)
              buildActionTile(ctx, theme, Icons.cloud_outlined, 'Search Cloud', 'Find published identities in the directory', () {
                Navigator.pop(ctx);
                showSearchCloudDialog(context, onRefresh: onRefresh);
              }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ));
  }

  void _showManualContactDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => _ManualAddContactDialog(
        onAdd: onAddContact,
        onError: onError,
        onRefresh: onRefresh,
      ),
    );
  }

  Future<void> _importLockFlow(BuildContext context) async {
    final path = await fileChooserService.pickFile('Import Lock File');
    if (path == null) return;

    try {
      final outcome = await onImportLockFile(path, '');
      await onRefresh();
      if (!context.mounted) return;
      await handleImportOutcome(
        context,
        outcome,
        onConfirm: onConfirmContactImport,
        onStatus: (msg) => showImportStatus(context, msg),
      );
      if (!context.mounted) return;
      await maybeOfferCloudInvite(context, outcome);
      await onRefresh(); // pick up the invited/unreachable state
    } catch (e) {
      if (!context.mounted) return;
      onError('Import failed: $e');
    }
  }

  void _scanQRFlow(BuildContext context) {
    _scanQRMobile(context);
  }


  void _scanQRMobile(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LockQRScannerPage(
          onImportLockQRPart: onImportLockQRPart,
          onConfirmContactImport: onConfirmContactImport,
          onRefresh: onRefresh,
        ),
      ),
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
        // Incoming friend requests (cloud) — renders nothing when cloud is
        // off, signed out, or the inbox is empty.
        _CloudRequestsSection(onRefresh: onRefresh),
        if (contacts.isNotEmpty) ...[
          ...contacts.map((c) {
            final alias = c['alias'] as String;
            return ListTile(
              dense: true,
              leading: const Icon(Icons.person_outline, size: 20),
              title: Text(alias),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (cloudReady)
                    _ConnectionIcon(
                      contact: c,
                      onStatus: onStatus,
                      onError: onError,
                      onRefresh: onRefresh,
                    ),
                  _ContactViewIconButton(
                    alias: alias,
                    onShowContact: onShowContact,
                    showViewDialog: _showViewDialog,
                  ),
                  IconButton(
                    icon: const Icon(Icons.share, size: 20),
                    tooltip: 'Share Lock',
                    onPressed: () => _showExportMenu(context, alias),
                  ),
                  _ContactEditIconButton(
                    alias: alias,
                    onShowContact: onShowContact,
                    showEditDialog: _showEditDialog,
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Remove',
                    onPressed: () => _showRemoveDialog(context, alias),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 8),
        ],
        if (contacts.isEmpty && searchQuery.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              'No matching contacts',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        if (hasKeys)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: isLoading ? null : () => _showAddContactSheet(context),
              style: buttonStyle,
              icon: const Icon(Icons.person_add),
              label: const Text('Add Contact'),
            ),
          ),
      ],
    );
  }
}

// _CloudRequestsSection lists incoming friend requests with Accept/Decline.
// Self-contained: it gates on cloud enabled + signed in, loads its own data,
// and collapses to nothing when there is nothing to show. Errors surface
// inline in the section — never on the main screen.
class _CloudRequestsSection extends StatefulWidget {
  const _CloudRequestsSection({required this.onRefresh});

  final Future<void> Function() onRefresh;

  @override
  State<_CloudRequestsSection> createState() => _CloudRequestsSectionState();
}

class _CloudRequestsSectionState extends State<_CloudRequestsSection> {
  List<Map<String, dynamic>> _requests = [];
  final Map<String, String> _done = {}; // request id → result line
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final st = jsonDecode(await cloudService.cloudUIState()) as Map<String, dynamic>;
      if (st['enabled'] != true || st['signed_in'] != true) return;
      final raw = await cloudService.contactRequests();
      if (!mounted) return;
      setState(() {
        _requests = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
      });
    } catch (_) {
      // Unreachable server or locked identities: the section stays hidden.
    }
  }

  Future<void> _respond(String id, bool accept) async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final raw = await cloudService.respondContactRequest(id, accept);
      final res = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _done[id] = accept ? 'Added as "${(res['alias'] as String?) ?? ''}"' : 'Declined';
        _busy = false;
      });
      if (accept) await widget.onRefresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  String _shortFp(String fp) => fp.length <= 12 ? fp : '${fp.substring(0, 12)}…';

  @override
  Widget build(BuildContext context) {
    if (_requests.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final open = _requests.where((r) => !_done.containsKey(r['id'])).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text('Requests ($open)', style: theme.textTheme.titleSmall),
        ),
        ..._requests.map((r) {
          final id = (r['id'] as String?) ?? '';
          final name = (r['name'] as String?) ?? '';
          final alias = (r['alias'] as String?) ?? '';
          final email = (r['email'] as String?) ?? '';
          final title = alias.isEmpty ? name : '$name ($alias)';
          final subtitleParts = [
            if (email.isNotEmpty) email,
            _shortFp((r['fingerprint'] as String?) ?? ''),
          ];
          final done = _done[id];
          return ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.person_add_alt, size: 20),
            title: Text(title),
            subtitle: Text(subtitleParts.join(' · ')),
            trailing: done != null
                ? Text(done, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary))
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: _busy ? null : () => _respond(id, true),
                        child: const Text('Accept'),
                      ),
                      TextButton(
                        onPressed: _busy ? null : () => _respond(id, false),
                        child: Text('Decline', style: TextStyle(color: theme.colorScheme.error)),
                      ),
                    ],
                  ),
          );
        }),
        if (_error.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(_error, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
          ),
        const Divider(height: 24),
      ],
    );
  }
}

class _ContactViewIconButton extends StatefulWidget {
  const _ContactViewIconButton({
    required this.alias,
    required this.onShowContact,
    required this.showViewDialog,
  });

  final String alias;
  final Future<String> Function(String alias) onShowContact;
  final void Function(BuildContext context, String alias, String json) showViewDialog;

  @override
  State<_ContactViewIconButton> createState() => _ContactViewIconButtonState();
}

class _ContactViewIconButtonState extends State<_ContactViewIconButton> {
  var _isLoading = false;

  Future<void> _handleTap() async {
    setState(() => _isLoading = true);
    try {
      final json = await widget.onShowContact(widget.alias);
      if (!mounted || json.isEmpty) return;
      widget.showViewDialog(context, widget.alias, json);
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
        tooltip: 'Loading...',
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

class _ContactEditIconButton extends StatefulWidget {
  const _ContactEditIconButton({
    required this.alias,
    required this.onShowContact,
    required this.showEditDialog,
  });

  final String alias;
  final Future<String> Function(String alias) onShowContact;
  final void Function(BuildContext context, String alias, String json) showEditDialog;

  @override
  State<_ContactEditIconButton> createState() => _ContactEditIconButtonState();
}

class _ContactEditIconButtonState extends State<_ContactEditIconButton> {
  var _isLoading = false;

  Future<void> _handleTap() async {
    setState(() => _isLoading = true);
    try {
      final json = await widget.onShowContact(widget.alias);
      if (!mounted || json.isEmpty) return;
      widget.showEditDialog(context, widget.alias, json);
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
        tooltip: 'Loading...',
        onPressed: null,
      );
    }
    return IconButton(
      icon: const Icon(Icons.edit, size: 20),
      tooltip: 'Edit',
      onPressed: _handleTap,
    );
  }
}

/// Full-screen Lock QR scanner. Accumulates animated QR frames in any
/// order, showing N-of-M progress.
class LockQRScannerPage extends StatefulWidget {
  const LockQRScannerPage({
    super.key,
    required this.onImportLockQRPart,
    required this.onConfirmContactImport,
    required this.onRefresh,
  });

  final Future<QRPartResult> Function(String partJSON, String alias) onImportLockQRPart;
  final Future<void> Function(String token) onConfirmContactImport;
  final Future<void> Function() onRefresh;

  @override
  State<LockQRScannerPage> createState() => LockQRScannerPageState();
}

class LockQRScannerPageState extends State<LockQRScannerPage> {
  final _scannedParts = <String>{};
  bool _completed = false;
  bool _processing = false;
  int _received = 0;
  int _total = 0;
  String _statusText = 'Point camera at the Lock QR';

  void _onMultiScan(Codes codes) async {
    if (_completed || _processing) return;
    for (final code in codes.codes) {
      if (!code.isValid) continue;
      final data = code.text;
      if (data == null || data.isEmpty) continue;
      if (_scannedParts.contains(data)) continue;
      _scannedParts.add(data);

      setState(() => _processing = true);

      try {
        final result = await widget.onImportLockQRPart(data, '');
        if (!mounted) return;
        if (result.complete) {
          _completed = true;
          setState(() {
            _received = result.total > 0 ? result.total : 1;
            _total = _received;
            _statusText = 'Processing…';
          });
          await widget.onRefresh();
          if (!mounted) return;
          final outcome = result.outcome;
          if (outcome == null) {
            // No structured result (older payload); fall back to a plain notice.
            await showMessageDialog(context, 'Contact Import', 'Contact imported');
            if (!mounted) return;
            Navigator.of(context).pop();
            return;
          }
          // Applied → success notice; key rotation/revocation → the
          // fingerprint-verification confirm dialog, then apply.
          await handleImportOutcome(
            context,
            outcome,
            onConfirm: widget.onConfirmContactImport,
            onStatus: (msg) => showImportStatus(context, msg),
          );
          if (!mounted) return;
          await maybeOfferCloudInvite(context, outcome);
          if (!mounted) return;
          await widget.onRefresh(); // pick up the invited state
          if (!mounted) return;
          Navigator.of(context).pop();
          return;
        }
        setState(() {
          _received = result.received;
          _total = result.total;
          _processing = false;
          _statusText = 'Capturing… $_received of $_total';
        });
      } catch (e) {
        if (!mounted) return;
        _scannedParts.remove(data);
        setState(() {
          _processing = false;
          _statusText = 'Point camera at the Lock QR';
        });
        unawaited(showMessageDialog(context, 'Scan Error', '$e'));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scan Lock QR'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ReaderWidget(
                  isMultiScan: true,
                  onMultiScan: _onMultiScan,
                  codeFormat: Format.qrCode,
                  tryHarder: true,
                  tryInverted: true,
                  resolution: ResolutionPreset.max,
                  showScannerOverlay: false,
                  showFlashlight: false,
                  showToggleCamera: false,
                  showGallery: false,
                  // Short delay so the animated frame sequence is captured
                  // faster than it cycles.
                  scanDelay: const Duration(milliseconds: 150),
                ),
                const CustomPaint(
                  painter: _QRGuideOverlayPainter(),
                ),
              ],
            ),
          ),
          // Status bar at bottom
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            color: Colors.black,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _statusText,
                  style: TextStyle(
                    color: _processing ? Colors.amber : Colors.white,
                    fontSize: 16,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(
                  value: _total > 0 ? _received / _total : 0,
                  minHeight: 6,
                  borderRadius: BorderRadius.circular(3),
                  backgroundColor: Colors.white12,
                  color: _completed ? Colors.green : Colors.lightBlueAccent,
                ),
                const SizedBox(height: 8),
                Text(
                  _total > 0 ? '$_received of $_total frames' : 'Waiting for first frame…',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints a single centered square guide for aiming at the Lock QR.
class _QRGuideOverlayPainter extends CustomPainter {
  const _QRGuideOverlayPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    final squareSize = min(size.width, size.height) * 0.70;
    final startX = (size.width - squareSize) / 2;
    final startY = (size.height - squareSize) / 2;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(startX, startY, squareSize, squareSize),
        const Radius.circular(8),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _QRGuideOverlayPainter oldDelegate) => false;
}

class _EditContactDialog extends StatefulWidget {
  final String alias;
  final String contactJson;
  final Future<void> Function(String alias, String nickname, String firstName, String lastName, String email, String encPubKey, String signPubKey, String fingerprint) onSave;
  final void Function(String message) onError;
  final Future<void> Function() onRefresh;

  const _EditContactDialog({
    required this.alias,
    required this.contactJson,
    required this.onSave,
    required this.onError,
    required this.onRefresh,
  });

  @override
  State<_EditContactDialog> createState() => _EditContactDialogState();
}

class _EditContactDialogState extends State<_EditContactDialog> {
  late final TextEditingController _nicknameCtrl;
  late final TextEditingController _firstNameCtrl;
  late final TextEditingController _lastNameCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _encPubKeyCtrl;
  late final TextEditingController _signPubKeyCtrl;

  @override
  void initState() {
    super.initState();
    final c = jsonDecode(widget.contactJson) as Map<String, dynamic>;
    _nicknameCtrl = TextEditingController(text: c['nickname'] as String? ?? '');
    _firstNameCtrl = TextEditingController(text: c['first_name'] as String? ?? '');
    _lastNameCtrl = TextEditingController(text: c['last_name'] as String? ?? '');
    _emailCtrl = TextEditingController(text: c['email'] as String? ?? '');
    _encPubKeyCtrl = TextEditingController(text: c['enc_pub_key'] as String? ?? '');
    _signPubKeyCtrl = TextEditingController(text: c['sign_pub_key'] as String? ?? '');
  }

  @override
  void dispose() {
    _nicknameCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _encPubKeyCtrl.dispose();
    _signPubKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_encPubKeyCtrl.text.isEmpty) {
      unawaited(showMessageDialog(context, 'Validation Error', 'Encryption Lock is required'));
      return;
    }
    Navigator.of(context).pop();
    try {
      // Fingerprint is recomputed from the locks by the backend — pass empty.
      await widget.onSave(
        widget.alias,
        _nicknameCtrl.text,
        _firstNameCtrl.text,
        _lastNameCtrl.text,
        _emailCtrl.text,
        _encPubKeyCtrl.text,
        _signPubKeyCtrl.text,
        '',
      );
    } catch (e) {
      widget.onError('Failed to update contact: $e');
    }
    await widget.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit ${widget.alias}'),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Alias',
                  border: OutlineInputBorder(),
                ),
                child: Text(widget.alias),
              ),
              const SizedBox(height: 12),
              TextField(controller: _nicknameCtrl, autofocus: true, inputFormatters: aliasInputFormatters, decoration: const InputDecoration(labelText: 'Nickname (your shortcut)', helperText: 'a-z, 0-9, - and _', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: _firstNameCtrl, decoration: const InputDecoration(labelText: 'First Name', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: _lastNameCtrl, decoration: const InputDecoration(labelText: 'Last Name', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: _emailCtrl, decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: _encPubKeyCtrl, textInputAction: TextInputAction.next, decoration: const InputDecoration(labelText: 'Encryption Lock *', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(
                controller: _signPubKeyCtrl,
                decoration: const InputDecoration(labelText: 'Signing Lock', border: OutlineInputBorder(), helperText: 'Fingerprint is computed from the locks automatically.'),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _ManualAddContactDialog extends StatefulWidget {
  final Future<void> Function(String alias, String nickname, String firstName, String lastName, String email, String encPubKey, String signPubKey, String fingerprint) onAdd;
  final void Function(String message) onError;
  final Future<void> Function() onRefresh;

  const _ManualAddContactDialog({
    required this.onAdd,
    required this.onError,
    required this.onRefresh,
  });

  @override
  State<_ManualAddContactDialog> createState() => _ManualAddContactDialogState();
}

class _ManualAddContactDialogState extends State<_ManualAddContactDialog> {
  final _aliasCtrl = TextEditingController();
  final _nicknameCtrl = TextEditingController();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _encPubKeyCtrl = TextEditingController();
  final _signPubKeyCtrl = TextEditingController();

  @override
  void dispose() {
    _aliasCtrl.dispose();
    _nicknameCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _encPubKeyCtrl.dispose();
    _signPubKeyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_aliasCtrl.text.isEmpty) {
      unawaited(showMessageDialog(context, 'Validation Error', 'Alias is required'));
      return;
    }
    if (_encPubKeyCtrl.text.isEmpty) {
      unawaited(showMessageDialog(context, 'Validation Error', 'Encryption Lock is required'));
      return;
    }
    Navigator.of(context).pop();
    try {
      // Fingerprint is recomputed from the locks by the backend — pass empty.
      await widget.onAdd(
        _aliasCtrl.text,
        _nicknameCtrl.text,
        _firstNameCtrl.text,
        _lastNameCtrl.text,
        _emailCtrl.text,
        _encPubKeyCtrl.text,
        _signPubKeyCtrl.text,
        '',
      );
    } catch (e) {
      widget.onError('Failed to add contact: $e');
    }
    await widget.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Contact'),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: _aliasCtrl, autofocus: true, textInputAction: TextInputAction.next, inputFormatters: aliasInputFormatters, decoration: const InputDecoration(labelText: 'Alias * (their handle)', helperText: 'a-z, 0-9, - and _', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: _nicknameCtrl, inputFormatters: aliasInputFormatters, decoration: const InputDecoration(labelText: 'Nickname (your shortcut)', helperText: 'a-z, 0-9, - and _', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: _firstNameCtrl, decoration: const InputDecoration(labelText: 'First Name', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: _lastNameCtrl, decoration: const InputDecoration(labelText: 'Last Name', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: _emailCtrl, decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(controller: _encPubKeyCtrl, textInputAction: TextInputAction.next, decoration: const InputDecoration(labelText: 'Encryption Lock *', border: OutlineInputBorder())),
              const SizedBox(height: 12),
              TextField(
                controller: _signPubKeyCtrl,
                decoration: const InputDecoration(labelText: 'Signing Lock', border: OutlineInputBorder(), helperText: 'Fingerprint is computed from the locks automatically.'),
                onSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: _submit,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// _ConnectionIcon renders a contact's cloud-connection handshake state as
/// the row's first trailing icon (cloud on + signed in only):
///   (none)      → invite to connect (tap → confirm → send)
///   invited     → waiting; re-clickable once the invite is >7 days old
///   connected   → static check — the handshake completed (never inferred)
///   unreachable → invite bounced (not on cloud, or identity not listed);
///                 tap retries in case they joined/published since.
class _ConnectionIcon extends StatelessWidget {
  const _ConnectionIcon({
    required this.contact,
    required this.onStatus,
    required this.onError,
    required this.onRefresh,
  });

  final Map<String, dynamic> contact;
  final void Function(String message) onStatus;
  final void Function(String message) onError;
  final Future<void> Function() onRefresh;

  Future<void> _invite(BuildContext context, String alias, String title, String body) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
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
    if (yes != true) return;
    try {
      await cloudService.inviteContact(alias);
      onStatus('Invite sent — $alias can now accept and add your lock.');
    } catch (e) {
      onError(cleanBridgeError(e));
    }
    await onRefresh(); // reflect invited/unreachable
  }

  @override
  Widget build(BuildContext context) {
    final alias = contact['alias'] as String? ?? '';
    final state = contact['cloud_connection'] as String? ?? '';
    final invitedAt = DateTime.tryParse(contact['invited_at'] as String? ?? '');
    final inviteAged = invitedAt == null ||
        DateTime.now().difference(invitedAt) > const Duration(days: 7);

    switch (state) {
      case 'connected':
        return const IconButton(
          icon: Icon(Icons.cloud_done, size: 20),
          tooltip: 'Connected on cloud',
          onPressed: null,
        );
      case 'invited':
        if (!inviteAged) {
          return const IconButton(
            icon: Icon(Icons.cloud_sync, size: 20),
            tooltip: 'Invite sent — waiting for them to accept',
            onPressed: null,
          );
        }
        return IconButton(
          icon: const Icon(Icons.cloud_sync, size: 20),
          tooltip: 'Invite sent a while ago — tap to re-send',
          onPressed: () => _invite(context, alias, 'Re-send invite to $alias?',
              'The earlier invite was not accepted yet. Send it again?'),
        );
      case 'unreachable':
        return IconButton(
          icon: const Icon(Icons.cloud_off, size: 20),
          tooltip: 'Not reachable on cloud — tap to retry',
          onPressed: () => _invite(
              context,
              alias,
              'Retry the invite?',
              '$alias may have joined Instacrypt Cloud since. To be reachable '
                  'they need to list their identity in the directory '
                  '(Settings → Keys → Publish) — or they can simply scan your QR back.'),
        );
      default:
        return IconButton(
          icon: const Icon(Icons.cloud_upload_outlined, size: 20),
          tooltip: 'Invite to connect',
          onPressed: () => _invite(context, alias, 'Invite $alias to connect?',
              'Send a cloud invite so they can add your lock back — no need to scan a second QR.'),
        );
    }
  }
}
