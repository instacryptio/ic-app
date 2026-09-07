// HomeController extracts the bridge-call wrappers from _HomePageState so the
// State class is left with UI/state responsibilities only. Each method here
// follows the same shape: toggle loading, call icfxService (often via the
// State's runUnlocked), refresh the relevant list. Errors rethrow — the
// calling settings tab catches them and routes through its own sheet-local
// onError display. The main-screen status bar is reserved for main-screen
// operations and must not receive sheet-triggered error text.
//
// The controller is constructed with callbacks back into the State for the
// few things it can't own: `setLoading` toggles the spinner,
// `refreshContacts` / `refreshIdentities` re-fetch the lists, and
// `runUnlocked` is the State-resident unlock+retry wrapper (which itself
// needs `BuildContext` for the passphrase / HW dialogs, so it stays in the
// State).
//
// Methods that need direct UI access (file pickers, dialogs that depend on
// State.mounted) stay in app.dart. This split keeps the boundary clean:
// State = "anything that touches UI / context / file system", controller =
// "translate UI intent into bridge calls + state refreshes".

import 'dart:convert';

import '../bridge/bridge.gen.dart';
import 'import_confirm.dart' show ImportOutcome;
import 'settings_contacts_tab.dart' show QRPartResult;

class HomeController {
  HomeController({
    required this.setLoading,
    required this.refreshContacts,
    required this.refreshIdentities,
    required this.refreshGroups,
    required this.runUnlocked,
  });

  final void Function(bool) setLoading;
  final Future<void> Function() refreshContacts;
  final Future<void> Function() refreshIdentities;
  final Future<void> Function() refreshGroups;
  final Future<T> Function<T>(Future<T> Function()) runUnlocked;

  // --- Group operations ---
  //
  // Groups are plaintext metadata (a name + member contact IDs) — no unlock /
  // HW tap needed, so they don't go through runUnlocked. Mutations rethrow;
  // the calling group dialog catches and routes to its sheet-local onError.

  Future<void> addGroup(String name, List<String> memberAliases) async {
    setLoading(true);
    try {
      await icfxService.addGroup(name, memberAliases);
      await refreshGroups();
    } finally {
      setLoading(false);
    }
  }

  Future<void> editGroup(String id, String name, List<String> memberAliases) async {
    setLoading(true);
    try {
      await icfxService.editGroup(id, name, memberAliases);
      await refreshGroups();
    } finally {
      setLoading(false);
    }
  }

  Future<void> removeGroup(String id) async {
    setLoading(true);
    try {
      await icfxService.removeGroup(id);
      await refreshGroups();
    } finally {
      setLoading(false);
    }
  }

  // --- Identity operations ---

  Future<void> revokeIdentity(String name) async {
    setLoading(true);
    try {
      await runUnlocked(() => icfxService.revokeIdentity(name));
      await refreshIdentities();
    } finally {
      setLoading(false);
    }
  }

  Future<void> rotateIdentity(String name, String alias, String email, String firstName, String lastName) async {
    setLoading(true);
    try {
      await runUnlocked(() => icfxService.rotateIdentity(name, alias, email, firstName, lastName));
      await refreshIdentities();
    } finally {
      setLoading(false);
    }
  }

  Future<void> editIdentity(String name, String alias, String email, String firstName, String lastName) async {
    setLoading(true);
    try {
      await runUnlocked(() => icfxService.editIdentity(name, alias, email, firstName, lastName, ''));
      await refreshIdentities();
    } finally {
      setLoading(false);
    }
  }

  Future<String> showIdentity(String name) {
    return runUnlocked(() => icfxService.showIdentity(name));
  }

  Future<String> exportLock(String name) {
    return runUnlocked(() => icfxService.exportLock(name));
  }

  Future<String> exportLockQR(String name) {
    return runUnlocked(() => icfxService.exportLockQR(name));
  }

  // --- Contact operations ---

  // confirmContactImport applies a cached key rotation/revocation after the
  // user confirms it in the fingerprint-verification dialog. The token
  // correlates this confirmation with the specific import that was prompted, so
  // a second import that overwrote the cache can't cause the wrong change to
  // apply.
  Future<void> confirmContactImport(String token) async {
    setLoading(true);
    try {
      await runUnlocked(() => icfxService.confirmContactImport(token));
      await refreshContacts();
    } finally {
      setLoading(false);
    }
  }

  Future<void> addContact(String alias, String nickname, String firstName, String lastName, String email, String encPubKey, String signPubKey, String fingerprint) async {
    setLoading(true);
    try {
      await runUnlocked(() => icfxService.addContact(alias, nickname, firstName, lastName, email, encPubKey, signPubKey, fingerprint));
      await refreshContacts();
    } finally {
      setLoading(false);
    }
  }

  // importLockFile parses the import outcome so the caller can apply it (new
  // contact, applied by the backend) or prompt for confirmation (a key
  // rotation/revocation for an existing contact).
  Future<ImportOutcome> importLockFile(String path, String alias) async {
    setLoading(true);
    try {
      final result = await runUnlocked(() => icfxService.importLockFile(path, alias));
      await refreshContacts();
      return ImportOutcome.fromJsonString(result);
    } finally {
      setLoading(false);
    }
  }

  Future<String> importLockQR(String qrData, String alias) async {
    setLoading(true);
    try {
      final result = await runUnlocked(() => icfxService.importLockQR(qrData, alias));
      await refreshContacts();
      return result;
    } finally {
      setLoading(false);
    }
  }

  // importLockQRPart returns a QRPartResult signalling whether the animated
  // QR frame accumulation completed. Used by the QR scanner page to know
  // when to dismiss and to show N-of-M progress.
  // Errors propagate as exceptions — the caller is expected to surface them
  // through its sheet-local error path, not the main-screen status bar.
  Future<QRPartResult> importLockQRPart(String partJSON, String alias) async {
    final result = await runUnlocked(() => icfxService.importLockQRPart(partJSON, alias));
    final parsed = jsonDecode(result) as Map<String, dynamic>;
    final complete = parsed['complete'] as bool? ?? false;
    final received = parsed['received'] as int? ?? 0;
    final total = parsed['total'] as int? ?? 0;
    if (complete) {
      await refreshContacts();
      final resultObj = parsed['result'];
      final outcome = resultObj is Map<String, dynamic>
          ? ImportOutcome.fromJson(resultObj)
          : null;
      return QRPartResult(
        complete: true,
        received: received,
        total: total,
        outcome: outcome,
      );
    }
    return QRPartResult(complete: false, received: received, total: total);
  }

  Future<void> removeContact(String alias) async {
    setLoading(true);
    try {
      await runUnlocked(() => icfxService.removeContact(alias));
      await refreshContacts();
    } finally {
      setLoading(false);
    }
  }

  Future<void> editContact(String alias, String nickname, String firstName, String lastName, String email, String encPubKey, String signPubKey, String fingerprint) async {
    setLoading(true);
    try {
      await runUnlocked(() => icfxService.editContact(alias, nickname, firstName, lastName, email, encPubKey, signPubKey, fingerprint));
      await refreshContacts();
    } finally {
      setLoading(false);
    }
  }

  Future<String> showContact(String alias) {
    return runUnlocked(() => icfxService.showContact(alias));
  }

  Future<String> exportContactLock(String alias) {
    return runUnlocked(() => icfxService.exportContactLock(alias));
  }

  Future<String> exportContactLockQR(String alias) {
    return runUnlocked(() => icfxService.exportContactLockQR(alias));
  }

  // --- Settings (no unlock required) ---

  Future<String> getSettings() {
    return icfxService.getSettings();
  }

  Future<void> setSetting(String key, String value) {
    return icfxService.setSetting(key, value);
  }
}
