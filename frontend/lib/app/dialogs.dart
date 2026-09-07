// Dialog builders extracted from app.dart so the HomePage state isn't
// dragging ~400 lines of pure-UI boilerplate around.
//
// Pattern: each function takes a BuildContext (plus any data it needs) and
// returns a Future of the user's result, or void for fire-and-forget dialogs.
// No reference to HomePage state — anything they need is passed in. Anything
// they should trigger goes through an injected callback.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../bridge/bridge.gen.dart';
import '../bridge/filechooser.dart';
import 'settings_shared.dart' show aliasInputFormatters, showMessageDialog;

/// showPassphraseDialog prompts for the session unlock passphrase. Returns the
/// entered bytes as a mutable Uint8List the caller MUST wipe (via fillRange)
/// after dispatch. The intermediate TextEditingController.text String is
/// unavoidable (Flutter text input writes to a String); its lifetime is
/// bounded to this dialog's scope. Returns null on cancel.
///
/// StatefulWidget-backed so the controller's lifecycle is owned by State.
/// See feedback_dialog_controller_pattern.md for why closure-based
/// controllers race with the dialog's exit animation.
Future<Uint8List?> showPassphraseDialog(BuildContext context) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => const _PassphraseDialog(),
  );
  if (result == null) return null;
  return Uint8List.fromList(utf8.encode(result));
}

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog();
  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Passphrase Required'),
      content: TextField(
        controller: _controller,
        obscureText: true,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Passphrase',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// showNewPassphraseDialog prompts for a new passphrase with confirmation.
/// Returns the entered bytes as a Uint8List the caller MUST wipe after use.
/// Returns null on cancel. StatefulWidget-backed; see _PassphraseDialog.
Future<Uint8List?> showNewPassphraseDialog(BuildContext context) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => const _NewPassphraseDialog(),
  );
  if (result == null) return null;
  return Uint8List.fromList(utf8.encode(result));
}

class _NewPassphraseDialog extends StatefulWidget {
  const _NewPassphraseDialog();
  @override
  State<_NewPassphraseDialog> createState() => _NewPassphraseDialogState();
}

class _NewPassphraseDialogState extends State<_NewPassphraseDialog> {
  final _passController = TextEditingController();
  final _confirmController = TextEditingController();

  @override
  void dispose() {
    _passController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_passController.text != _confirmController.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passphrases do not match')),
      );
      return;
    }
    if (_passController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passphrase cannot be empty')),
      );
      return;
    }
    Navigator.of(context).pop(_passController.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Passphrase'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _passController,
            obscureText: true,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Passphrase',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirmController,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Confirm Passphrase',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// showCreateKeyDialog collects the fields for a new identity. Returns a map
/// with keys: name, alias, email, firstName, lastName, useHWKey ("true"/
/// "false"). Returns null on cancel. StatefulWidget-backed; see
/// _PassphraseDialog.
Future<Map<String, String>?> showCreateKeyDialog(BuildContext context) {
  return showDialog<Map<String, String>>(
    context: context,
    builder: (_) => const _CreateKeyDialog(),
  );
}

class _CreateKeyDialog extends StatefulWidget {
  const _CreateKeyDialog();
  @override
  State<_CreateKeyDialog> createState() => _CreateKeyDialogState();
}

class _CreateKeyDialogState extends State<_CreateKeyDialog> {
  final _nameCtrl = TextEditingController();
  final _aliasCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  bool _useHWKey = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _aliasCtrl.dispose();
    _emailCtrl.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    if (_nameCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name is required')),
      );
      return;
    }
    Navigator.of(context).pop({
      'name': _nameCtrl.text,
      'alias': _aliasCtrl.text,
      'email': _emailCtrl.text,
      'firstName': _firstNameCtrl.text,
      'lastName': _lastNameCtrl.text,
      'useHWKey': _useHWKey ? 'true' : 'false',
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Create Identity'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
              ),
              // Name is the only required field; submit on Enter from here.
              // Optional fields below remain accessible via Tab / click.
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _aliasCtrl,
              inputFormatters: aliasInputFormatters,
              decoration: const InputDecoration(
                labelText: 'Alias (optional)',
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
                labelText: 'First Name (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _lastNameCtrl,
              decoration: const InputDecoration(
                labelText: 'Last Name (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            // Modern SwitchListTile (not a checkbox) for HW-key opt-in.
            // Subtitle reminds the user that icfx does not program slots —
            // they must do it via ykman or KeePassXC first.
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SwitchListTile(
                title: const Text('Protect with a hardware key'),
                subtitle: const Text(
                  'Slot 2 must already be programmed for HMAC-SHA1 (via ykman or KeePassXC).',
                  style: TextStyle(fontSize: 12),
                ),
                value: _useHWKey,
                onChanged: (v) => setState(() => _useHWKey = v),
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
          onPressed: _submit,
          child: const Text('Create'),
        ),
      ],
    );
  }
}

/// showNFCTapDialog displays a "tap your hardware key" prompt while the
/// platform plugin is listening for an NFC/USB connection. The dialog
/// blocks return until the caller dismisses it (typically when the
/// hardware_key plugin returns a response or the user cancels).
///
/// Returns `Future<void>` for convenience; the dismissal is driven by the
/// caller via Navigator.pop, not by user interaction. The Cancel button
/// pops the dialog with a cancellation marker so the caller can
/// distinguish user-cancel from plugin-completion.
///
/// Convention: caller wraps the plugin call in unawaited(showDialog(...))
/// and pops the dialog itself after the plugin Future completes (success
/// or error). The Cancel button hooks into onCancel() so the caller can
/// also cancel the in-flight plugin op.
Future<void> showNFCTapDialog(
  BuildContext context, {
  required VoidCallback onCancel,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Tap Your Hardware Key'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Hold your YubiKey to the back of the phone, or plug it into the USB-C/Lightning port.'),
            SizedBox(height: 12),
            Text(
              'The device may briefly flash. If your slot requires a touch, the LED will pulse — tap the metal contact.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              onCancel();
              Navigator.of(ctx).pop();
            },
            child: const Text('Cancel'),
          ),
        ],
      ),
    ),
  );
}

/// showHWNotPluggedInDialog blocks until the user either plugs in a key and
/// clicks Retry (returns true) or cancels (returns false). Shown when an
/// operation needs a hardware key and none is detected.
Future<bool> showHWNotPluggedInDialog(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Hardware Key Required'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('No hardware key detected.'),
          SizedBox(height: 8),
          Text(
            'This identity is protected by a hardware key. Plug it in and click Retry.',
          ),
          SizedBox(height: 12),
          Text(
            'Compatible: YubiKey, NitroKey, OnlyKey (HMAC-SHA1 on slot 2).',
            style: TextStyle(fontSize: 12, color: Colors.grey),
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
          child: const Text('Retry'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// showOverwriteConfirmDialog asks the user to confirm replacing an existing
/// file. Returns true on confirm, false on cancel.
Future<bool> showOverwriteConfirmDialog(BuildContext context, String path) async {
  final filename = path.split(Platform.pathSeparator).last;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('File Already Exists'),
      content: Text('$filename already exists. Do you want to replace it?'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Replace'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// showSuccessDialog reports successful encrypt/decrypt to the user with
/// platform-appropriate follow-up actions (Share on mobile, Open Folder on
/// desktop).
///
/// The dialog is non-dismissible (no barrier-tap, no back-button) so the
/// temp file backing Share stays alive until the user explicitly hits
/// Done. Lets the user share to multiple recipients (or leave the app,
/// switch back, share again) without the temp file getting cleaned up
/// from under them. Cleanup runs exactly once, when Done is pressed.
void showSuccessDialog(BuildContext context, String message, SaveFileResult result,
    {Future<void> Function()? onICShare}) {
  final isMobile = Platform.isAndroid || Platform.isIOS;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Success'),
        content: Text(message),
        // Row order: [Open Folder] [Share (mobile)] [IC Share] [Done];
        // AlertDialog actions wrap via OverflowBar on narrow widths.
        actions: [
          if (result.savedPath != null)
            OutlinedButton(
              onPressed: () async {
                try {
                  await fileChooserService.openDirectory(result.savedPath!);
                } catch (e) {
                  if (!ctx.mounted) return;
                  unawaited(showMessageDialog(ctx, 'Open Folder Failed', '$e'));
                }
              },
              child: const Text('Open Folder'),
            ),
          if (isMobile)
            OutlinedButton(
              onPressed: () async {
                try {
                  await fileChooserService.shareFile(result.tempPath ?? result.savedPath!);
                } catch (e) {
                  if (!context.mounted) return;
                  unawaited(showMessageDialog(context, 'Share Failed', '$e'));
                }
              },
              child: const Text('Share'),
            ),
          if (onICShare != null)
            OutlinedButton(
              onPressed: () async {
                try {
                  await onICShare();
                } catch (e) {
                  if (!context.mounted) return;
                  unawaited(showMessageDialog(context, 'IC Share Failed', '$e'));
                }
              },
              child: const Text('IC Share'),
            ),
          FilledButton(
            onPressed: () {
              fileChooserService.cleanupTemp(result);
              Navigator.of(ctx).pop();
            },
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );
}

/// showImportPassphraseDialog prompts for the export passphrase that was
/// chosen when the backup file was created. Returns the passphrase as UTF-8
/// bytes the caller MUST wipe (fillRange) once the flow ends — it reaches Go
/// over the secure raw-bytes channel via stageBundlePassphrase (peek→import
/// flows stage the same bytes twice; the staged copy is single-use). Returns
/// null on cancel.
///
/// Backed by a StatefulWidget so the TextEditingController's lifecycle is
/// tied to the widget's State and disposed only AFTER the dialog is fully
/// unmounted. The simpler closure-based pattern (controller in the
/// function body, controller.dispose() after await) races with the
/// dialog's exit animation when another dialog opens immediately after —
/// the TextField gets rebuilt mid-tear-down and tries to listen to the
/// disposed controller.
Future<Uint8List?> showImportPassphraseDialog(BuildContext context) async {
  final result = await showDialog<String>(
    context: context,
    builder: (_) => const _ImportPassphraseDialog(),
  );
  if (result == null || result.isEmpty) return null;
  return Uint8List.fromList(utf8.encode(result));
}

class _ImportPassphraseDialog extends StatefulWidget {
  const _ImportPassphraseDialog();
  @override
  State<_ImportPassphraseDialog> createState() => _ImportPassphraseDialogState();
}

class _ImportPassphraseDialogState extends State<_ImportPassphraseDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Backup Passphrase'),
      content: TextField(
        controller: _controller,
        obscureText: true,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Backup passphrase',
          helperText: 'The passphrase you chose when exporting this backup.',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('OK'),
        ),
      ],
    );
  }
}

/// showImportConflictDialog prompts the user to choose a new name when the
/// backup's identity name collides with one that already exists locally.
/// Returns the new name on confirm, or null on cancel.
///
/// Same StatefulWidget rationale as showImportPassphraseDialog: keeps the
/// TextEditingController alive until the dialog is fully torn down so a
/// follow-on dialog opening immediately after can't rebuild this TextField
/// against a disposed controller.
Future<String?> showImportConflictDialog(BuildContext context, String existingName) {
  return showDialog<String>(
    context: context,
    builder: (_) => _ImportConflictDialog(existingName: existingName),
  );
}

class _ImportConflictDialog extends StatefulWidget {
  final String existingName;
  const _ImportConflictDialog({required this.existingName});
  @override
  State<_ImportConflictDialog> createState() => _ImportConflictDialogState();
}

class _ImportConflictDialogState extends State<_ImportConflictDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.existingName}-restored');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.isEmpty || _controller.text == widget.existingName) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick a name different from the existing one.')),
      );
      return;
    }
    Navigator.of(context).pop(_controller.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Name Conflict'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("An identity named '${widget.existingName}' already exists."),
          const SizedBox(height: 8),
          const Text('Pick a different name to restore the backup under:'),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'New name',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('Restore'),
        ),
      ],
    );
  }
}

/// showPreserveHWDialog asks whether to preserve hardware-key protection
/// when restoring an HW-protected backup. Returns true (preserve), false
/// (drop HW protection, store under non-HW backend), or null (cancel the
/// whole import).
Future<bool?> showPreserveHWDialog(BuildContext context) async {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Hardware Key Protection'),
      content: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This identity was protected by a hardware key on the source device.'),
          SizedBox(height: 12),
          Text(
            'Preserve hardware-key protection on this device? You\'ll need your hardware key ready when the import runs.',
          ),
          SizedBox(height: 12),
          Text(
            'Choosing "No" stores the identity without hardware-key protection (passphrase or keychain only).',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('No'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Yes, preserve'),
        ),
      ],
    ),
  );
}

/// ProfileImportOptions captures the user's choices in the profile-import
/// confirmation dialog: whether to bring the source's settings and/or path
/// overrides across, and whether to preserve HW-key protection for HW-
/// flagged identities in the bundle.
class ProfileImportOptions {
  final bool includeSettings;
  final bool includePaths;
  final bool preserveHW;
  const ProfileImportOptions({
    required this.includeSettings,
    required this.includePaths,
    required this.preserveHW,
  });
}

/// showProfileImportConfirmDialog warns the user that profile import is
/// destructive (replaces all local identities, contacts, and settings) and
/// collects the three import options. The "Preserve hardware-key
/// protection" checkbox only appears when the bundle has at least one
/// HW-flagged identity (passed in via hasHWInBundle).
///
/// Returns the chosen options on confirm, or null on cancel.
Future<ProfileImportOptions?> showProfileImportConfirmDialog(
  BuildContext context, {
  required bool hasHWInBundle,
}) async {
  var includeSettings = true;
  var includePaths = true;
  var preserveHW = true;
  return showDialog<ProfileImportOptions>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Replace All Local Data?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Importing this profile backup will REPLACE all of your current:'),
              const SizedBox(height: 8),
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('• Identities and their keys'),
                    Text('• Contacts'),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'This cannot be undone. Make sure you have a backup of your current state if you want to keep it.',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 16),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: includeSettings,
                onChanged: (v) => setDialogState(() => includeSettings = v ?? true),
                title: const Text('Also import settings'),
                subtitle: const Text(
                  'Auto-lock, default identity, format, keystore preference',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                value: includePaths,
                onChanged: (v) => setDialogState(() => includePaths = v ?? true),
                title: const Text('Also import paths'),
                subtitle: const Text(
                  'Config / data / key directory overrides',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              if (hasHWInBundle)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: preserveHW,
                  onChanged: (v) => setDialogState(() => preserveHW = v ?? true),
                  title: const Text('Preserve hardware-key protection'),
                  subtitle: const Text(
                    'A hardware key will be required at import time',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.of(ctx).pop(ProfileImportOptions(
              includeSettings: includeSettings,
              includePaths: includePaths,
              preserveHW: preserveHW,
            )),
            child: const Text('Replace All'),
          ),
        ],
      ),
    ),
  );
}

/// showManualAddContactDialog is the manual contact-creation form (alias,
/// email, locks, fingerprint). On submit it calls onAdd with the field
/// values, then onRefresh. Returns immediately; the dialog manages its own
/// lifecycle. StatefulWidget-backed; see _PassphraseDialog.
void showManualAddContactDialog(
  BuildContext context, {
  required Future<void> Function(
    String alias,
    String nickname,
    String firstName,
    String lastName,
    String email,
    String encPubKey,
    String signPubKey,
    String fingerprint,
  ) onAdd,
  required Future<void> Function() onRefresh,
}) {
  showDialog(
    context: context,
    builder: (_) => _ManualAddContactDialog(onAdd: onAdd, onRefresh: onRefresh),
  );
}

class _ManualAddContactDialog extends StatefulWidget {
  final Future<void> Function(
    String alias,
    String nickname,
    String firstName,
    String lastName,
    String email,
    String encPubKey,
    String signPubKey,
    String fingerprint,
  ) onAdd;
  final Future<void> Function() onRefresh;
  const _ManualAddContactDialog({required this.onAdd, required this.onRefresh});
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
    if (_aliasCtrl.text.isEmpty || _encPubKeyCtrl.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Alias and Encryption Lock are required')),
      );
      return;
    }
    Navigator.of(context).pop();
    // Fingerprint is derived from the entered keys by the backend (never typed),
    // so it always identifies these exact keys — pass empty.
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

/// showTextPromptDialog is a minimal single-field prompt (label/PIN/password
/// style). Returns the entered text, or null on cancel. StatefulWidget so the
/// controller's lifecycle is owned by the dialog.
Future<String?> showTextPromptDialog(
  BuildContext context, {
  required String title,
  required String label,
  String? hint,
  bool obscure = false,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TextPromptDialog(title: title, label: label, hint: hint, obscure: obscure),
  );
}

class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.label,
    this.hint,
    this.obscure = false,
  });

  final String title;
  final String label;
  final String? hint;
  final bool obscure;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        obscureText: widget.obscure,
        decoration: InputDecoration(labelText: widget.label, helperText: widget.hint),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(context).pop(_ctrl.text), child: const Text('OK')),
      ],
    );
  }
}

/// showSearchCloudDialog searches the cloud directory and adds hits as
/// contacts — "Save Lock" (one-directional, they are not notified) or
/// "Add Friend" (also sends an encrypted contact request). Only reachable
/// when cloud is enabled and signed in (callers gate on cloudUIState).
Future<void> showSearchCloudDialog(
  BuildContext context, {
  required Future<void> Function() onRefresh,
}) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _SearchCloudDialog(onRefresh: onRefresh),
  );
}

class _SearchCloudDialog extends StatefulWidget {
  final Future<void> Function() onRefresh;

  const _SearchCloudDialog({required this.onRefresh});

  @override
  State<_SearchCloudDialog> createState() => _SearchCloudDialogState();
}

class _SearchCloudDialogState extends State<_SearchCloudDialog> {
  late final TextEditingController _queryCtrl;
  List<Map<String, dynamic>> _results = [];
  bool _searched = false;
  bool _busy = false;
  String _error = '';
  // fingerprint → status line once a row has been added.
  final Map<String, String> _added = {};

  @override
  void initState() {
    super.initState();
    _queryCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryCtrl.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final raw = await cloudService.directorySearch(query);
      if (!mounted) return;
      setState(() {
        _results = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
        _searched = true;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _add(Map<String, dynamic> entry, bool asFriend) async {
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final raw = await cloudService.addContactFromDirectory(jsonEncode(entry), asFriend);
      final res = jsonDecode(raw) as Map<String, dynamic>;
      final alias = (res['alias'] as String?) ?? '';
      var line = 'Added as "$alias"';
      if (res['friend_request_sent'] == true) line = '$line · request sent';
      if (res['updated'] == true) line = 'Updated "$alias"';
      if (!mounted) return;
      setState(() {
        _added[(entry['fingerprint'] as String?) ?? ''] = line;
        _busy = false;
      });
      await widget.onRefresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  String _shortFp(String fp) => fp.length <= 12 ? fp : '${fp.substring(0, 12)}…';

  Widget _resultRow(ThemeData theme, Map<String, dynamic> entry) {
    final name = (entry['display_name'] as String?) ?? '';
    final alias = (entry['alias'] as String?) ?? '';
    final email = (entry['email'] as String?) ?? '';
    final fp = (entry['fingerprint'] as String?) ?? '';
    final title = alias.isEmpty ? name : '$name ($alias)';
    final added = _added[fp];
    // Already in the local contact list (annotated by icfx) — can't be re-added.
    final alreadyContact = entry['already_added'] == true;
    final contactAlias = (entry['contact_alias'] as String?) ?? '';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: theme.textTheme.bodyMedium)),
              if (email.isNotEmpty)
                Text(email, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(_shortFp(fp),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
              if (alreadyContact)
                Text(
                  contactAlias.isEmpty
                      ? '✓ Already a contact'
                      : '✓ Already a contact ($contactAlias)',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
                )
              else if (added != null)
                Text(added, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary))
              else ...[
                OutlinedButton(
                  onPressed: _busy ? null : () => _add(entry, false),
                  child: const Text('Save Lock'),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _busy ? null : () => _add(entry, true),
                  child: const Text('Add Friend'),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Search Cloud Directory'),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'name, alias, or email',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _search,
                  child: const Text('Search'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_searched && _results.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('No published identities matched.', style: theme.textTheme.bodySmall),
              ),
            if (_results.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 280),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _results.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) => _resultRow(theme, _results[i]),
                ),
              ),
            const SizedBox(height: 8),
            Text(
              'Save Lock saves their lock (public key); they are not notified. '
              'Add Friend also sends an encrypted request so they can add you back.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
