import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../bridge/filechooser.dart';

/// _AliasInputFormatter lowercases input and strips anything outside the alias
/// charset (a-z 0-9 - _) as the user types, mirroring icfx's validate.Alias so
/// the field can never hold an invalid handle. The backend validates again —
/// this is a UX convenience, not the trust boundary.
class _AliasInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final filtered = newValue.text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '');
    return TextEditingValue(
      text: filtered,
      selection: TextSelection.collapsed(offset: filtered.length),
    );
  }
}

/// aliasInputFormatters constrain an alias TextField to a single lowercase word
/// of at most 32 chars using only a-z, 0-9, '-' and '_'. Shared by the create
/// and edit identity dialogs.
final List<TextInputFormatter> aliasInputFormatters = [
  LengthLimitingTextInputFormatter(32),
  _AliasInputFormatter(),
];

/// Show a simple message dialog. Use this instead of SnackBar when not on the home screen.
/// Returns a Future that completes when the user dismisses the dialog. Callers
/// SHOULD await this when their surrounding flow (e.g. a parent route's
/// `finally` block) is about to pop a route — otherwise the message dialog
/// stacks above the parent and the pop closes the wrong one.
Future<void> showMessageDialog(BuildContext context, String title, String message) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Shows a dialog prompting the user for an export passphrase (with confirmation).
/// Returns the passphrase as UTF-8 bytes the caller MUST wipe (fillRange)
/// after staging it via stageBundlePassphrase — same contract as
/// showPassphraseDialog. The in-dialog TextEditingController String is
/// unavoidable (Flutter text input); its lifetime is bounded to the dialog.
/// Returns null if the user cancelled.
/// StatefulWidget-backed so the TextEditingControllers' lifecycles are owned
/// by State.dispose, avoiding the closure-based dispose-after-await race.
Future<Uint8List?> showExportPassphraseDialog(BuildContext context, String title) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _ExportPassphraseDialog(title: title),
  );
  if (result == null) return null;
  return Uint8List.fromList(utf8.encode(result));
}

class _ExportPassphraseDialog extends StatefulWidget {
  final String title;
  const _ExportPassphraseDialog({required this.title});
  @override
  State<_ExportPassphraseDialog> createState() => _ExportPassphraseDialogState();
}

class _ExportPassphraseDialogState extends State<_ExportPassphraseDialog> {
  final _passphraseCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _errorText;
  bool _obscurePass = true;
  bool _obscureConfirm = true;

  @override
  void dispose() {
    _passphraseCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_passphraseCtrl.text.isEmpty) {
      setState(() => _errorText = 'Passphrase cannot be empty');
      return;
    }
    if (_passphraseCtrl.text != _confirmCtrl.text) {
      setState(() => _errorText = 'Passphrases do not match');
      return;
    }
    Navigator.of(context).pop(_passphraseCtrl.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This file contains your private keys. Store it securely.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _passphraseCtrl,
              obscureText: _obscurePass,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: 'Export passphrase',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(_obscurePass ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscurePass = !_obscurePass),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _confirmCtrl,
              obscureText: _obscureConfirm,
              decoration: InputDecoration(
                labelText: 'Confirm passphrase',
                border: const OutlineInputBorder(),
                errorText: _errorText,
                suffixIcon: IconButton(
                  icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Export'),
        ),
      ],
    );
  }
}

/// Shows the animated Lock QR dialog for [title]. The dialog opens
/// immediately with a loading indicator while [export] (a bridge call
/// returning base64 GIF bytes) runs, then plays the animation. Errors render
/// inside the dialog — never on the main-screen status bar.
Future<void> showLockQRDialog(
  BuildContext context, {
  required String title,
  required String saveBaseName,
  required Future<String> Function() export,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _LockQRDialog(title: title, saveBaseName: saveBaseName, export: export),
  );
}

class _LockQRDialog extends StatefulWidget {
  const _LockQRDialog({required this.title, required this.saveBaseName, required this.export});

  final String title;
  final String saveBaseName;
  final Future<String> Function() export;

  @override
  State<_LockQRDialog> createState() => _LockQRDialogState();
}

class _LockQRDialogState extends State<_LockQRDialog> {
  // The decoded bytes are created once and reused everywhere so Image.memory
  // keeps a stable cache key and the GIF animation doesn't restart on
  // rebuilds (e.g. the rotate button's setState).
  Uint8List? _gifBytes;
  String? _error;
  double _rotation = 0;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    try {
      final qrBase64 = await widget.export();
      if (!mounted) return;
      if (qrBase64.isEmpty) {
        setState(() => _error = 'Empty response from backend');
        return;
      }
      setState(() => _gifBytes = base64Decode(qrBase64));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Widget _buildBody(BuildContext ctx) {
    final error = _error;
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Theme.of(ctx).colorScheme.error),
            const SizedBox(height: 12),
            Text('QR generation failed', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(error, textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    }

    final gifBytes = _gifBytes;
    if (gifBytes == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text('Generating QR code…', style: Theme.of(ctx).textTheme.bodyMedium),
        ],
      );
    }

    return AnimatedRotation(
      turns: _rotation,
      duration: const Duration(milliseconds: 300),
      // SafeArea + SingleChildScrollView keeps the QR + actions accessible
      // when the window is shorter than the column's intrinsic height.
      // LayoutBuilder budgets QR height against the viewport so the other
      // elements always fit.
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              const reservedHeight = 220.0;
              final viewportH = MediaQuery.of(ctx).size.height;
              final qrMaxH = (viewportH - reservedHeight).clamp(120.0, viewportH);
              final qrW = constraints.maxWidth * 0.95;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.title,
                    style: Theme.of(ctx).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: qrW,
                    constraints: BoxConstraints(maxHeight: qrMaxH),
                    padding: const EdgeInsets.all(8),
                    child: Image.memory(
                      gifBytes,
                      width: qrW,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.save_alt),
                        label: const Text('Save GIF'),
                        onPressed: () async {
                          final result = await fileChooserService.saveFile(
                            'Save QR Code',
                            '${widget.saveBaseName}.gif',
                            '',
                            bytes: gifBytes,
                          );
                          if (result.cancelled || !ctx.mounted) return;
                          unawaited(showMessageDialog(ctx, 'Saved', 'QR code saved to ${result.savedPath}'));
                        },
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.copy),
                        label: const Text('Copy'),
                        onPressed: () async {
                          final item = DataWriterItem();
                          item.add(Formats.gif(gifBytes));
                          await SystemClipboard.instance?.write([item]);
                          if (!ctx.mounted) return;
                          unawaited(showMessageDialog(ctx, 'Copied', 'QR code copied to clipboard'));
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Close'),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog.fullscreen(
      child: Stack(
        alignment: Alignment.center,
        children: [
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          _buildBody(context),
          // Rotate button — lets the QR face the scanning device
          if (_gifBytes != null && (Platform.isAndroid || Platform.isIOS))
            Positioned(
              right: 16,
              child: FloatingActionButton.small(
                onPressed: () => setState(() => _rotation = _rotation == 0 ? 0.5 : 0),
                child: const Icon(Icons.screen_rotation),
              ),
            ),
        ],
      ),
    );
  }
}

/// A circular selection indicator used by multi-select contact lists in place
/// of the default square checkbox: an outlined ring when unselected, a filled
/// primary circle with a check when selected.
Widget circleCheckbox(BuildContext context, bool selected) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.only(left: 8, right: 16),
    child: Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? cs.primary : Colors.transparent,
        border: Border.all(color: selected ? cs.primary : cs.outline, width: 2),
      ),
      child: selected ? Icon(Icons.check, size: 14, color: cs.onPrimary) : null,
    ),
  );
}

Widget buildActionTile(BuildContext context, ThemeData theme, IconData icon, String title, String subtitle, VoidCallback onTap, {Color? color}) {
  final tileColor = color ?? theme.colorScheme.primary;
  return Material(
    color: theme.colorScheme.surfaceContainerHighest,
    borderRadius: BorderRadius.circular(12),
    child: InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: tileColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 18, color: tileColor),
            ),
            const SizedBox(width: 12),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: color)),
                if (subtitle.isNotEmpty)
                  Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

Widget detailRow(String label, String value) {
  if (value.isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: SelectableText(value),
        ),
      ],
    ),
  );
}

/// groupFingerprint renders a fingerprint in space-separated blocks of 4 for
/// readable out-of-band comparison. Mirrors icfx crypto.FormatGrouped so the
/// grouping is identical to what ic-cli shows.
String groupFingerprint(String fp) {
  final b = StringBuffer();
  for (var i = 0; i < fp.length; i += 4) {
    if (i > 0) b.write(' ');
    final end = i + 4 > fp.length ? fp.length : i + 4;
    b.write(fp.substring(i, end));
  }
  return b.toString();
}

Widget keyRow(String label, String value, BuildContext context) {
  if (value.isEmpty) return const SizedBox.shrink();
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 140,
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
        ),
        Expanded(child: SelectableText(value)),
        IconButton(
          icon: const Icon(Icons.copy, size: 18),
          tooltip: 'Copy $label',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () async {
            final item = DataWriterItem();
            item.add(Formats.plainText(value));
            await SystemClipboard.instance?.write([item]);
            if (!context.mounted) return;
            unawaited(showMessageDialog(context, 'Copied', '$label copied to clipboard'));
          },
        ),
      ],
    ),
  );
}

class CollapsibleKeyRow extends StatefulWidget {
  const CollapsibleKeyRow({
    super.key,
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  State<CollapsibleKeyRow> createState() => _CollapsibleKeyRowState();
}

class _CollapsibleKeyRowState extends State<CollapsibleKeyRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.value.isEmpty) return const SizedBox.shrink();

    final truncated = widget.value.length > 12
        ? '${widget.value.substring(0, 12)}...'
        : widget.value;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(widget.label, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: _expanded
                  ? SelectableText(widget.value)
                  : Text(truncated, style: Theme.of(context).textTheme.bodyMedium),
            ),
          ),
          IconButton(
            icon: Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
            ),
            tooltip: _expanded ? 'Collapse' : 'Expand',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => setState(() => _expanded = !_expanded),
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.copy, size: 18),
            tooltip: 'Copy ${widget.label}',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () async {
              final item = DataWriterItem();
              item.add(Formats.plainText(widget.value));
              await SystemClipboard.instance?.write([item]);
              if (!context.mounted) return;
              unawaited(showMessageDialog(context, 'Copied', '${widget.label} copied to clipboard'));
            },
          ),
        ],
      ),
    );
  }
}
