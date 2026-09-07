// Profile export / import orchestration. Extracted from app.dart so the
// _HomePageState class doesn't carry the ~150 lines of multi-step UX
// (file picks, passphrase dialogs, peek-then-confirm, HW pre-flight,
// post-import re-init). Same boundary as `dialogs.dart` and
// `home_controller.dart`: anything self-contained that doesn't tightly
// depend on State internals leaves State.
//
// The State stays responsible for things the flow file can't know: how to
// re-initialize after a destructive import (which knobs the State holds,
// what _ensureUnlocked depends on). That's passed in as a callback.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../bridge/bridge.gen.dart';
import '../bridge/filechooser.dart';
import 'dialogs.dart';
import 'hw_flow.dart';
import 'settings_shared.dart' show showExportPassphraseDialog, showMessageDialog;

/// runExportProfileFlow drives the export end-to-end: passphrase prompt →
/// backend export → file picker → success/failure dialog.
Future<void> runExportProfileFlow(
  BuildContext context, {
  required void Function(String, {bool isError}) setStatus,
}) async {
  final pass = await showExportPassphraseDialog(context, 'Export Profile');
  if (pass == null || !context.mounted) return;

  String base64Data;
  try {
    await icfxService.stageBundlePassphrase(pass);
    base64Data = await icfxService.exportProfile();
  } on FlugoException catch (e) {
    if (!context.mounted) return;
    unawaited(showMessageDialog(context, 'Export Failed', '$e'));
    return;
  } finally {
    pass.fillRange(0, pass.length, 0);
  }

  if (!context.mounted) return;
  final bytes = base64Decode(base64Data);
  // Default filename comes from icfx (<alias-or-name>-profile.tar.icfx); the
  // user can still rename in the save dialog.
  final defaultName = await icfxService.profileBackupFilename();
  if (!context.mounted) return;
  final result = await fileChooserService.saveFile(
    'Export Profile',
    defaultName,
    '',
    bytes: Uint8List.fromList(bytes),
  );
  if (result.cancelled || !context.mounted) return;
  if (result.error != null) {
    setStatus(result.error!, isError: true);
    return;
  }
  unawaited(showMessageDialog(context, 'Profile Exported', 'Backup written successfully.'));
}

/// runImportProfileFlow drives the destructive import end-to-end:
/// file pick → passphrase → manifest peek → options dialog → optional HW
/// pre-flight → backend import → caller-provided re-init → success dialog.
///
/// reinitializeAfterImport is called after a successful import. The State
/// owns it because it touches local fields the flow file shouldn't know
/// about (refresh identities, refresh contacts, hasKeys, _keychainAvailable,
/// re-run _ensureUnlocked since the imported config may have changed
/// keystore / default identity).
Future<void> runImportProfileFlow(
  BuildContext context, {
  required void Function(String, {bool isError}) setStatus,
  required Future<void> Function() reinitializeAfterImport,
}) async {
  final path = await fileChooserService.pickFile('Import Profile');
  if (path == null || !context.mounted) return;

  final pass = await showImportPassphraseDialog(context);
  if (pass == null || !context.mounted) return;
  try {
    await _importProfileFlowStaged(context, path, pass,
        setStatus: setStatus, reinitializeAfterImport: reinitializeAfterImport);
  } finally {
    pass.fillRange(0, pass.length, 0);
  }
}

// _importProfileFlowStaged is the body of the import flow with the
// passphrase held as wipeable bytes; it stages the secret over the secure
// channel before each consuming call (peek, then the import itself — the
// staged copy is single-use).
Future<void> _importProfileFlowStaged(
  BuildContext context,
  String path,
  Uint8List pass, {
  required void Function(String, {bool isError}) setStatus,
  required Future<void> Function() reinitializeAfterImport,
}) async {
  String manifestJson;
  try {
    await icfxService.stageBundlePassphrase(pass);
    manifestJson = await icfxService.peekProfileManifest(path);
  } on FlugoException catch (e) {
    if (!context.mounted) return;
    unawaited(showMessageDialog(context, 'Import Failed', '$e'));
    return;
  }

  final manifest = jsonDecode(manifestJson) as Map<String, dynamic>;
  final identities = (manifest['identities'] as List<dynamic>?) ?? const [];
  final hasHWInBundle = identities.any((id) => (id as Map<String, dynamic>)['hw_key'] == true);

  if (!context.mounted) return;
  final opts = await showProfileImportConfirmDialog(context, hasHWInBundle: hasHWInBundle);
  if (opts == null) return;

  if (opts.preserveHW && hasHWInBundle) {
    if (Platform.isAndroid || Platform.isIOS) {
      // Mobile: run the shared NFC ceremony once per HW identity, each tapping
      // against that identity's own bundle challenge, before importProfile.
      Map<String, dynamic> challenges;
      try {
        await icfxService.stageBundlePassphrase(pass);
        challenges = jsonDecode(await icfxService.peekProfileHWChallenges(path)) as Map<String, dynamic>;
      } on FlugoException catch (e) {
        if (!context.mounted) return;
        unawaited(showMessageDialog(context, 'Import Failed', '$e'));
        return;
      }
      for (final entry in challenges.entries) {
        if (!context.mounted) return;
        final ok = await prepareHWForImport(context, entry.key, base64Decode(entry.value as String));
        if (!ok) return; // user cancelled a tap
      }
    } else {
      while (!await icfxService.hasAnyHardwareKey()) {
        if (!context.mounted) return;
        final retry = await showHWNotPluggedInDialog(context);
        if (!retry) return;
      }
    }
  }

  try {
    await icfxService.stageBundlePassphrase(pass);
    await icfxService.importProfile(path, opts.includeSettings, opts.includePaths, opts.preserveHW);
  } on FlugoException catch (e) {
    if (!context.mounted) return;
    unawaited(showMessageDialog(context, 'Import Failed', '$e'));
    return;
  }

  await reinitializeAfterImport();
  if (!context.mounted) return;
  unawaited(showMessageDialog(context, 'Profile Imported', 'Backup restored successfully.'));
}
