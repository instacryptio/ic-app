import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:dropdown_search/dropdown_search.dart';
import 'package:flutter/material.dart';

import '../bridge/bridge.gen.dart';
import '../bridge/filechooser.dart';
import '../main.dart' show CustomTitlebarStyle, flugoOnDeepLink, titlebarStyle;
import 'cloud_notifications.dart';
import 'sync_flow.dart';
import 'webauthn_support.dart';
import 'unlock_flow.dart';
import 'dialogs.dart';
import 'home_controller.dart';
import 'hw_flow.dart';
import 'ic_share.dart';
import 'import_confirm.dart';
import 'onboarding/welcome_wizard.dart';
import 'profile_flow.dart';
import 'settings_contacts_tab.dart' show LockQRScannerPage;
import 'settings_shared.dart' show buildActionTile, circleCheckbox, showExportPassphraseDialog, showMessageDialog;
import 'settings_sheet.dart';
import 'titlebar.dart';

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        Platform.isLinux || Platform.isMacOS || Platform.isWindows;

    return MaterialApp(
      title: 'Instacrypt',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF9BBB2E),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      builder: (context, child) {
        if (!isDesktop) return child!;
        return Overlay(
          initialEntries: [
            OverlayEntry(
              builder: (context) => Column(
                children: [
                  ValueListenableBuilder<CustomTitlebarStyle>(
                    valueListenable: titlebarStyle,
                    builder: (context, style, _) {
                      if (style == CustomTitlebarStyle.native) {
                        return const SizedBox.shrink();
                      }
                      return const CustomTitleBar(title: 'Instacrypt');
                    },
                  ),
                  Expanded(child: child!),
                ],
              ),
            ),
          ],
        );
      },
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  String? _selectedFilePath;
  String? _selectedFileName;
  bool _isDecryptMode = false;

  List<String> _selectedContacts = [];
  List<Map<String, dynamic>> _contacts = [];
  List<Map<String, dynamic>> _groups = [];
  List<Map<String, dynamic>> _identities = [];
  String? _selectedIdentityName;

  bool _hasKeys = false;
  bool _showWelcome = false;
  bool _useMyLock = false;
  bool _alsoSelf = false;
  bool _keychainAvailable = false;
  // Starts true so the home screen shows a spinner from the very first
  // frame and stays on it until _initialize completes (incl. the unlock
  // passphrase dialog + post-unlock refresh). Without this, the home
  // screen renders behind the passphrase dialog and there's a confusing
  // no-spinner gap after the dialog closes while identities load.
  bool _isInitializing = true;
  bool _isLoading = false;
  bool _isDragging = false;
  String _statusMessage = '';
  bool _isError = false;

  // Cloud notices: invite count for the settings-gear badge plus one-shot
  // dialogs (new invites, accepted requests, key rotations/revocations).
  Timer? _noticesTimer;
  int _unseenNotifCount = 0;
  bool _cloudEnabled = false;
  bool _cloudSignedIn = false;
  bool _syncBusy = false;

  late final HomeController _controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = HomeController(
      setLoading: (v) {
        if (!mounted) return;
        setState(() => _isLoading = v);
      },
      refreshContacts: _refreshContacts,
      refreshIdentities: _refreshIdentities,
      refreshGroups: _refreshGroups,
      runUnlocked: _runUnlocked,
    );
    _initialize();
    // The poll is metadata-only and returns zeros while cloud is off or
    // signed out, so it's safe to fire blindly.
    _noticesTimer = Timer.periodic(const Duration(seconds: 60), (_) => _pollCloudNotices());
    Future.delayed(const Duration(seconds: 3), _pollCloudNotices);

    // instacrypt://notifications (email bounce page → app) opens the bell
    // drawer. Cold-start links are buffered by main.dart and delivered here.
    flugoOnDeepLink((uri) {
      if (!mounted || _showWelcome) return;
      if (uri.host == 'notifications' || uri.path.contains('notifications')) {
        _openNotificationsDrawer(context);
      }
    });
  }

  @override
  void dispose() {
    _noticesTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The bell drawer replaced the old one-shot notice/invite dialogs: the
  // poll only feeds the badges now; everything renders as drawer history.
  Future<void> _pollCloudNotices() async {
    if (!mounted || _showWelcome) return;
    Map<String, dynamic> res;
    try {
      res = jsonDecode(await cloudService.cloudNotices()) as Map<String, dynamic>;
    } catch (_) {
      return; // best-effort poll
    }
    if (!mounted) return;
    setState(() {
      _cloudEnabled = res['enabled'] == true;
      _cloudSignedIn = res['signed_in'] == true;
      _unseenNotifCount = (res['unseen_count'] as num?)?.toInt() ?? 0;
    });
  }

  // _openNotificationsDrawer shows the bell drawer; an invite's View action
  // closes it and lands on the Contacts tab.
  Future<void> _openNotificationsDrawer(BuildContext sheetContext) async {
    await showCloudNotificationsDrawer(
      context,
      onOpenContacts: () {
        Navigator.of(context).popUntil((r) => r.isFirst);
        _showSettingsSheet(initialTab: 1);
      },
    );
    await _pollCloudNotices(); // badge refresh after the drawer closes
  }

  // Lock the backend when the app goes to background. The OS may suspend
  // or kill the process at any point after this; clearing the in-memory
  // session passphrase enclave before that happens means a heap dump or
  // memory snapshot of the suspended process won't yield the passphrase.
  // On resume the user re-enters their passphrase via _ensureUnlocked.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      // Fire-and-forget; we don't need the result and any error is non-fatal.
      icfxService.lock().catchError((_) {});
    }
  }

  Future<void> _initialize() async {
    await _checkKeychainAvailable();

    // First-launch gate: show the welcome wizard until it has been completed.
    // The backend auto-migrates existing users (who already have keys) past it.
    try {
      if (await icfxService.shouldShowWelcome()) {
        if (!mounted) return;
        setState(() {
          _showWelcome = true;
          _isInitializing = false;
        });
        return;
      }
    } on FlugoException catch (e) {
      _setStatus('Error: $e', isError: true);
      setState(() => _isInitializing = false);
      return;
    }

    bool hasKeys;
    try {
      hasKeys = await icfxService.hasKeys();
    } on FlugoException catch (e) {
      _setStatus('Error checking keys: $e', isError: true);
      setState(() => _isInitializing = false);
      return;
    }

    if (!hasKeys) {
      setState(() {
        _hasKeys = false;
        _isInitializing = false;
      });
      return;
    }

    // Keys exist. Unlock if any are file-backed (Unlock is a no-op for
    // pure-keychain setups since IsUnlocked already returns true).
    final ok = await _ensureUnlocked();
    if (!ok) {
      setState(() => _isInitializing = false);
      return;
    }

    // Kick the cloud auto-sync engine (interval + instant server events).
    // Best-effort: it self-gates on cloud-enabled + signed-in.
    try {
      await cloudService.ensureAutoSync();
    } on FlugoException {
      // Non-fatal — manual Sync Now still works from the Cloud tab.
    }

    setState(() {
      _hasKeys = true;
      _isInitializing = true;
    });
    try {
      await _refreshContacts();
      await _refreshGroups();
      await _refreshIdentities();
      // After identities load, _selectedIdentityName is populated. For an
      // HW-protected default, verify the plugged-in key is correct by
      // touching the identity once — same openIdentity path used by every
      // encrypt/decrypt op, but eager at launch so wrong-key shows up here
      // rather than on the user's first crypto attempt.
      await _verifyDefaultHWAtLaunch();
    } finally {
      setState(() => _isInitializing = false);
    }
  }

  Future<void> _checkKeychainAvailable() async {
    try {
      final result = await icfxService.keychainAvailable();
      setState(() => _keychainAvailable = result);
    } on FlugoException catch (e) {
      // Surface Android keyring diagnostic errors so user can report them
      _setStatus('Keychain/keyring: $e', isError: true);
    }
  }

  Future<void> _refreshContacts() async {
    try {
      // listContacts reads a plaintext file — no unlock / HW tap needed,
      // so we call it directly instead of through _runUnlocked. Wrapping
      // it would force an _ensureUnlocked call which (on mobile with an
      // HW-protected default identity) would spuriously prompt for an
      // HW tap just to enumerate contacts.
      final result = await icfxService.listContacts();
      final list = jsonDecode(result) as List<dynamic>;
      setState(() {
        _contacts = list.cast<Map<String, dynamic>>();
      });
    } on FlugoException catch (e) {
      _setStatus('Error loading contacts: $e', isError: true);
    }
  }

  // Loads contact groups from the plaintext groups store (same direct-read
  // rationale as _refreshContacts — no unlock / HW tap needed).
  Future<void> _refreshGroups() async {
    try {
      final result = await icfxService.listGroups();
      final list = jsonDecode(result) as List<dynamic>;
      setState(() {
        _groups = list.cast<Map<String, dynamic>>();
      });
    } on FlugoException catch (e) {
      _setStatus('Error loading groups: $e', isError: true);
    }
  }

  // Group names, for distinguishing group entries from contacts in the picker.
  Set<String> get _groupNames =>
      _groups.map((g) => g['name'] as String).toSet();

  // The Select-Contacts pool: contact aliases + group names, case-insensitively
  // alphabetical. A selected group is expanded to its members by the backend.
  List<String> get _recipientItems {
    final items = [
      ..._contacts.map((c) => c['alias'] as String),
      ..._groupNames,
    ];
    items.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return items;
  }

  // Renders a picker row with a leading icon marking groups vs contacts. The
  // trailing circular selection indicator is added by checkBoxBuilder.
  Widget _recipientItemBuilder(BuildContext context, String item, bool isDisabled, bool isSelected) {
    final isGroup = _groupNames.contains(item);
    return ListTile(
      dense: true,
      leading: Icon(isGroup ? Icons.groups : Icons.person_outline, size: 20),
      title: Text(item),
    );
  }

  Future<void> _refreshIdentities() async {
    try {
      // listIdentities reads the plaintext index — no unlock / HW tap
      // needed. Same rationale as _refreshContacts above.
      final result = await icfxService.listIdentities();
      final list = jsonDecode(result) as List<dynamic>;
      setState(() {
        _identities = list.cast<Map<String, dynamic>>();
        // ListIdentities now returns minimal index entries:
        // {name, backend, hw_key, is_default}. The previous "is_primary"
        // field is gone — the configured default is what the UI selects.
        final defaults = _identities.where((id) => id['is_default'] == true);
        if (defaults.isNotEmpty) {
          _selectedIdentityName ??= defaults.first['name'] as String;
        }
      });
    } on FlugoException catch (e) {
      _setStatus('Error loading identities: $e', isError: true);
    }
  }

  // _homeSyncNow runs the SAME sync flow as Settings → Cloud → Sync Now
  // (sync_flow.dart) — only the busy indicator and status surface differ:
  // the identity-row segment spins and outcomes land in the main status line.
  Future<void> _homeSyncNow() async {
    Future<bool> run(Future<void> Function() action) async {
      setState(() => _syncBusy = true);
      try {
        await action();
        return true;
      } catch (e) {
        final msg = e is FlugoException ? e.message : e.toString();
        _setStatus(msg.replaceFirst('Exception: ', ''), isError: true);
        return false;
      } finally {
        if (mounted) setState(() => _syncBusy = false);
      }
    }

    final webAuthnSupported = await platformWebAuthnSupported();
    if (!mounted) return;
    await runCloudSyncFlow(
      context,
      onStatus: (m) => _setStatus(m),
      onError: (m) => _setStatus(m, isError: true),
      run: run,
      webAuthnSupported: webAuthnSupported,
    );
    // A pull may have updated the local contact/identity stores — re-read them
    // so newly synced contacts appear without an app restart.
    if (mounted) {
      await _refreshContacts();
      await _refreshGroups();
      await _refreshIdentities();
    }
  }

  void _setStatus(String message, {bool isError = false}) {
    setState(() {
      _statusMessage = message;
      _isError = isError;
    });
  }

  void _selectFile(String path) {
    final name = path.split(Platform.pathSeparator).last;
    final isIcfx = path.endsWith('.icfx');
    setState(() {
      _selectedFilePath = path;
      _selectedFileName = name;
      _isDecryptMode = isIcfx;
      if (isIcfx) {
        _useMyLock = true;
        _alsoSelf = false;
        _selectedContacts = [];
      }
      _statusMessage = '';
    });
  }

  Future<void> _pickFile() async {
    final path = await fileChooserService.pickFile('Select File');
    if (path == null) return;
    _selectFile(path);
  }

  Future<bool> _createKeys() async {
    final details = await showCreateKeyDialog(context);
    if (details == null) return false;

    final useHWKey = details['useHWKey'] == 'true';

    // HW pre-flight before any keystore writes. Desktop: presence loop
    // (go-hid needs the device for slot-2 check + smoke test inside
    // CreateKeys). Mobile: full NFC dance — generate challenge, tap,
    // inject response — so CreateKeys can persist the challenge file
    // and derive the KEK from the pre-fetched response.
    if (useHWKey) {
      if (!mounted) return false;
      if (!await ensureHWForNewIdentity(context, details['name']!)) return false;
    }

    setState(() => _isLoading = true);
    try {
      // For file-backed setups (no keychain), seed the session passphrase
      // before CreateKeys — the new identity's keys will be encrypted with
      // it. For keychain setups, no passphrase is needed.
      if (!_keychainAvailable) {
        if (!mounted) return false;
        final ppBytes = await showNewPassphraseDialog(context);
        if (ppBytes == null) return false;
        try {
          await icfxService.unlock(ppBytes);
        } finally {
          ppBytes.fillRange(0, ppBytes.length, 0);
        }
      }
      await icfxService.createKeys(
        details['name']!,
        details['alias']!,
        details['email']!,
        details['firstName'] ?? '',
        details['lastName'] ?? '',
        useHWKey,
      );
      final hasKeys = await icfxService.hasKeys();
      setState(() => _hasKeys = hasKeys);
      if (_hasKeys) {
        await _refreshIdentities();
      }
      return true;
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _removeIdentity(String name) async {
    setState(() => _isLoading = true);
    try {
      // Removing the default identity re-keys its cloud resources to a successor
      // (chosen here). The backend asks for one via a need_successor marker.
      // Removing the ONLY identity is blocked until the user confirms a
      // force-delete (need_force marker). We prompt and retry until removed or
      // cancelled.
      var successor = '';
      var force = false;
      while (true) {
        final result = await _runUnlocked(() => icfxService.removeIdentity(name, successor, force));
        Map<String, dynamic>? marker;
        try {
          marker = jsonDecode(result) as Map<String, dynamic>;
        } catch (_) {
          marker = null; // plain success message
        }
        if (marker == null) break;
        if (marker['need_successor'] == true) {
          if (!mounted) return;
          final candidates = ((marker['candidates'] as List<dynamic>?) ?? const []).cast<String>();
          final chosen = await _pickSuccessor(name, candidates);
          if (chosen == null || chosen.isEmpty) return; // cancelled
          successor = chosen;
          continue;
        }
        if (marker['need_force'] == true) {
          if (!mounted) return;
          if (!await _confirmForceDeleteLast(name)) return; // cancelled
          force = true;
          continue;
        }
        break; // unknown/empty marker — treat as done
      }
      final hk = await icfxService.hasKeys();
      setState(() => _hasKeys = hk);
      if (_hasKeys) {
        await _refreshIdentities();
        return;
      }
      setState(() {
        _contacts = [];
        _identities = [];
        _selectedIdentityName = null;
        _useMyLock = false;
        _alsoSelf = false;
        _selectedContacts = [];
      });
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // _confirmForceDeleteLast shows the danger dialog before force-deleting the
  // user's ONLY identity. Its cloud data isn't lost — but it's unreadable until
  // re-keyed from a device that still holds the up-to-date local copy.
  Future<bool> _confirmForceDeleteLast(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('⚠ Delete your only identity?'),
        content: Text(
          '"$name" is your ONLY identity. Deleting it permanently destroys its keys.\n\n'
          'Any cloud data (contacts, groups, settings, notifications) sealed to it becomes '
          'UNREADABLE — the only way to repair it is to re-key that data from a device that '
          'still holds the most up-to-date copy (the "Re-key Cloud Data" action).',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete anyway'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // _pickSuccessor asks which identity should take over as default before the
  // current default is removed; its cloud resources are re-keyed to the choice.
  Future<String?> _pickSuccessor(String victim, List<String> candidates) async {
    if (candidates.isEmpty) return null;
    var selected = candidates.first;
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Choose a new default identity'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('"$victim" is your default identity. Its cloud contacts, groups, '
                  'and settings will be re-keyed to the identity that takes over.'),
              const SizedBox(height: 12),
              for (final c in candidates)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                      selected == c ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                  title: Text(c),
                  onTap: () => setLocal(() => selected = c),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(selected),
                child: const Text('Remove & re-key')),
          ],
        ),
      ),
    );
  }

  // _setDefaultIdentity changes the default identity (re-keying its cloud
  // resources to it via the backend/icfx handoff), then refreshes the list.
  Future<void> _setDefaultIdentity(String name) async {
    setState(() => _isLoading = true);
    try {
      await _runUnlocked(() => icfxService.setDefaultIdentity(name));
      await _refreshIdentities();
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // _cloudShareAvailable gates the IC Share button: cloud enabled + signed in.
  Future<bool> _cloudShareAvailable() async {
    try {
      final st = jsonDecode(await cloudService.cloudUIState()) as Map<String, dynamic>;
      return st['enabled'] == true && st['signed_in'] == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _submit({bool force = false}) async {
    if (_selectedFilePath == null) return;

    setState(() => _isLoading = true);
    try {
      // Validate recipient selection for encrypt mode
      if (!_isDecryptMode && !_useMyLock && !_alsoSelf && _selectedContacts.isEmpty) {
        unawaited(showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('No Recipient Selected'),
            content: const Text('Select at least one contact, enable "Also encrypt to me", or use "Use my Lock".'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        ));
        return;
      }

      final idName = _selectedIdentityName ?? '';
      String resultJSON;
      String suggestedName;

      if (_isDecryptMode) {
        resultJSON = await _runUnlocked(() => icfxService.decrypt(_selectedFilePath!, idName, force));
        final basename = _selectedFilePath!.split(Platform.pathSeparator).last;
        suggestedName = basename.endsWith('.icfx')
            ? basename.substring(0, basename.length - 5)
            : '$basename.decrypted';
      } else {
        // "Use my Lock" = self-only (no contacts). Otherwise the selected
        // contacts, plus self when the "Also encrypt to me" toggle is on.
        final recipients = _useMyLock ? <String>[] : _selectedContacts;
        final alsoSelf = _useMyLock ? true : _alsoSelf;
        resultJSON = await _runUnlocked(() =>
            icfxService.encrypt(_selectedFilePath!, recipients, alsoSelf, idName, force));
        suggestedName = '${_selectedFilePath!.split(Platform.pathSeparator).last}.icfx';
      }

      _setStatus('');
      if (!mounted) return;

      final result = await fileChooserService.handleWriteResult(resultJSON, suggestedName);

      // File exists — ask user to confirm overwrite
      if (result.exists) {
        setState(() => _isLoading = false);
        if (!mounted) return;
        final confirmed = await showOverwriteConfirmDialog(context, result.savedPath!);
        if (!confirmed || !mounted) return;
        await _submit(force: true);
        return;
      }

      if (result.cancelled || !mounted) return;
      if (result.error != null) {
        _setStatus(result.error!, isError: true);
        return;
      }

      // Build message with optional verify/warning info from decrypt
      var message = _isDecryptMode ? 'Decrypted successfully' : 'Encrypted successfully';
      final decoded = jsonDecode(resultJSON) as Map<String, dynamic>;
      final verifyMsg = decoded['verify_msg'] as String? ?? '';
      final revokedWarning = decoded['revoked_warning'] as String? ?? '';
      if (verifyMsg.isNotEmpty) message += '\n$verifyMsg';
      if (revokedWarning.isNotEmpty) message += '\n$revokedWarning';
      // Advisory warnings from encrypt (composed in icfx): e.g. a group member
      // skipped for having no active lock, so they won't be able to decrypt.
      final encWarnings = (decoded['warnings'] as List?)?.cast<String>() ?? const [];
      for (final w in encWarnings) {
        message += '\n⚠ $w';
      }

      // IC Share: offer to upload the just-encrypted file as a cloud share,
      // when the cloud is on and signed in. The share is addressed to the SAME
      // recipient set the file was encrypted to — contacts and/or groups, plus
      // the account's own devices (alsoSelf). "Use my Lock" is a pure self-share.
      final shareRecipients = _useMyLock ? <String>[] : _selectedContacts;
      final shareAlsoSelf = _useMyLock ? true : _alsoSelf;
      Future<void> Function()? onICShare;
      if (!_isDecryptMode && (shareRecipients.isNotEmpty || shareAlsoSelf)) {
        // tempPath first: on Android/Flatpak it is the Go-readable sandbox
        // copy (savedPath is the SAF/display location the backend cannot
        // open); on desktop both are the same path. Matches the native
        // Share button's ordering in dialogs.dart.
        final sharePath = result.tempPath ?? result.savedPath;
        if (sharePath != null && await _cloudShareAvailable()) {
          onICShare = () => runICShareFlow(
                context,
                filePath: sharePath,
                recipients: shareRecipients,
                alsoSelf: shareAlsoSelf,
              );
        }
      }
      if (!mounted) return;
      showSuccessDialog(context, message, result, onICShare: onICShare);
    } on FlugoException catch (e) {
      final segments = e.toString().split(': ');
      final cleaned = segments.length > 2
          ? segments.sublist(segments.length - 2).join(': ')
          : segments.last;
      _setStatus(cleaned, isError: true);
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // _ensureUnlocked checks the backend's session-unlock state and prompts for
  // a passphrase if needed (file-backed identities only). Returns true if the
  // backend is now unlocked (or never needed unlocking), false if the user
  // cancelled the dialog. After this returns true, the backend's sessionPass
  // enclave is populated and subsequent crypto calls won't need a passphrase
  // until Lock() / auto-lock fires.
  //
  // The passphrase travels as a Uint8List via the FlugoCallSecure path —
  // no JSON, no Dart String materialization on the way to the FFI boundary.
  // The bytes are wiped immediately after dispatch. The only unwipeable
  // copy is the TextEditingController.text String captured inside the
  // dialog; its lifetime is bounded to the dialog's scope.
  // Moved VERBATIM to unlock_flow.dart (ensureSessionUnlocked) so the
  // notifications drawer drives the same ceremony; this stays as a thin
  // delegation wiring HomePage's status line as the error sink.
  Future<bool> _ensureUnlocked() =>
      ensureSessionUnlocked(context, onError: (m) => _setStatus(m, isError: true));

  // _verifyDefaultHWAtLaunch issues a challenge-response to the default
  // identity's hardware key by opening (and immediately closing) the
  // identity via the existing showIdentity path — same openIdentity path
  // encrypt/decrypt use. Verifies the plugged-in device is the right one
  // for this identity (not just any HW device). Loops back to the
  // presence dialog if the challenge fails (wrong key, key removed).
  //
  // No-op when the default isn't HW-protected.
  Future<void> _verifyDefaultHWAtLaunch() async {
    if (!await icfxService.requiresHardwareKey()) return;
    final name = _selectedIdentityName;
    if (name == null || name.isEmpty) return;
    while (true) {
      try {
        // Mobile: fetch a fresh HW response via the platform plugin so
        // showIdentity has it cached. Desktop: no-op.
        if (!mounted) return;
        if (!await prepareHWForIdentity(context, name)) return;
        await icfxService.showIdentity(name);
        return;
      } on FlugoException {
        if (!mounted) return;
        final retry = await showHWNotPluggedInDialog(context);
        if (!retry) return;
      }
    }
  }

  // _runUnlocked wraps an operation that requires the session to be unlocked.
  // Equivalent to: ensureUnlocked + run; on a stale-cache "passphrase
  // required" error from a downstream call, re-prompt and retry once.
  //
  // On mobile, also pre-fetches an HW response for the default identity
  // when needed. Ops targeting a non-default HW identity should call
  // `prepareHWForIdentity(context, name)` themselves before the op.
  Future<T> _runUnlocked<T>(Future<T> Function() operation) async {
    if (!await _ensureUnlocked()) {
      throw FlugoException('Operation cancelled');
    }
    if (Platform.isAndroid || Platform.isIOS) {
      if (await icfxService.requiresHardwareKey()) {
        final name = _selectedIdentityName;
        if (name != null && mounted && !await prepareHWForIdentity(context, name)) {
          throw FlugoException('Operation cancelled');
        }
      }
    }
    try {
      return await operation();
    } on FlugoException catch (e) {
      if (!e.message.contains('passphrase required')) rethrow;
      // Stale cache (Lock fired between checks). Re-unlock and retry once.
      if (!await _ensureUnlocked()) {
        throw FlugoException('Operation cancelled');
      }
      return await operation();
    }
  }

  // _toggleHWKey enables or disables hardware-key protection on an existing
  // identity. The backend handles the re-encryption + rollback; we just
  // pre-flight the "is a key plugged in?" check when enabling and pass the
  // existing metadata through unchanged.
  Future<void> _toggleHWKey(String name, bool enable) async {
    if (enable) {
      while (!await icfxService.hasAnyHardwareKey()) {
        if (!mounted) return;
        final retry = await showHWNotPluggedInDialog(context);
        if (!retry) return;
      }
    }
    setState(() => _isLoading = true);
    try {
      // Fetch current meta so we can preserve alias/email/etc.
      final json = jsonDecode(await _controller.showIdentity(name)) as Map<String, dynamic>;
      await _runUnlocked(() => icfxService.editIdentity(
            name,
            json['alias'] as String? ?? '',
            json['email'] as String? ?? '',
            json['first_name'] as String? ?? '',
            json['last_name'] as String? ?? '',
            enable ? 'enable' : 'disable',
          ));
      await _refreshIdentities();
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // _importIdentity orchestrates the Restore-Identity flow:
  //   1. File picker → user selects a .icid identity backup
  //   2. Prompt for export passphrase
  //   3. Peek bundle → learn name + HW flag + name conflict
  //   4. If conflict → prompt for rename (rejected up-front for HW bundles)
  //   5. If HW → prompt to preserve, pre-flight device presence
  //   6. Call ImportIdentity → success or error toast
  Future<void> _importIdentity() async {
    final path = await fileChooserService.pickFile('Import Identity');
    if (path == null || !mounted) return;

    final pass = await showImportPassphraseDialog(context);
    if (pass == null) return;
    try {
      await _importIdentityFlow(path, pass);
    } finally {
      // The staged copies are consumed backend-side; this wipes the only
      // Dart-side plaintext bytes once the whole flow is over.
      pass.fillRange(0, pass.length, 0);
    }
  }

  // _importIdentityFlow drives peek → dialogs → import with the passphrase
  // bytes staged over the secure channel before each consuming call (the
  // staged enclave is single-use).
  Future<void> _importIdentityFlow(String path, Uint8List pass) async {
    String peekJson;
    try {
      await icfxService.stageBundlePassphrase(pass);
      peekJson = await icfxService.peekIdentityBundle(path);
    } on FlugoException catch (e) {
      if (!mounted) return;
      await showMessageDialog(context, 'Import Failed', '$e');
      return;
    }
    final peek = jsonDecode(peekJson) as Map<String, dynamic>;
    final name = peek['name'] as String;
    final hwKey = peek['hw_key'] == true;
    final conflict = peek['conflict'] == true;
    final hwChallengeB64 = peek['hw_challenge'] as String? ?? '';

    var renameTo = '';
    if (conflict) {
      if (!mounted) return;
      final newName = await showImportConflictDialog(context, name);
      if (newName == null) return;
      if (hwKey && newName != name) {
        if (!mounted) return;
        await showMessageDialog(
          context,
          'Rename Not Supported',
          'Hardware-key-protected backups cannot be renamed on import. Import with the original name and rename afterward.',
        );
        return;
      }
      renameTo = newName;
    }

    var preserveHW = false;
    if (hwKey) {
      if (!mounted) return;
      final choice = await showPreserveHWDialog(context);
      if (choice == null) return;
      preserveHW = choice;
      if (preserveHW) {
        if (!mounted) return;
        // Reuse the shared ceremony (NFC-primary on mobile, USB presence loop
        // on desktop), tapping against the bundle's own HW challenge.
        final ok = await prepareHWForImport(context, name, base64Decode(hwChallengeB64));
        if (!ok) return;
      }
    }

    setState(() => _isLoading = true);
    try {
      await _importIdentityWithSeedRetry(path, pass, preserveHW, renameTo);
      await _refreshIdentities();
      final hk = await icfxService.hasKeys();
      if (!mounted) return;
      setState(() => _hasKeys = hk);
      // Await dismissal so the surrounding spinner-dialog (in the caller's
      // finally) pops the spinner, not this message dialog.
      await showMessageDialog(context, 'Identity Restored', 'Backup restored successfully.');
    } on FlugoException catch (e) {
      if (!mounted) return;
      await showMessageDialog(context, 'Restore Failed', '$e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // _importIdentityWithSeedRetry wraps importIdentity with a single retry
  // path for the "passphrase required" error. That error is the backend's
  // signal that the destination keystore is file-backed and no session pass
  // has been seeded yet (e.g. first identity on a no-keychain platform).
  // The export passphrase decrypts the bundle but isn't reused for at-rest
  // encryption on this device, so we prompt for a NEW session passphrase
  // and retry the import once.
  Future<void> _importIdentityWithSeedRetry(String path, Uint8List pass, bool preserveHW, String renameTo) async {
    try {
      await icfxService.stageBundlePassphrase(pass);
      await icfxService.importIdentity(path, preserveHW, renameTo);
      return;
    } on FlugoException catch (e) {
      if (!e.message.contains('passphrase required')) rethrow;
    }
    if (!mounted) throw FlugoException('Import cancelled');
    final ppBytes = await showNewPassphraseDialog(context);
    if (ppBytes == null) throw FlugoException('Import cancelled');
    try {
      await icfxService.unlock(ppBytes);
    } finally {
      ppBytes.fillRange(0, ppBytes.length, 0);
    }
    await icfxService.stageBundlePassphrase(pass);
    await icfxService.importIdentity(path, preserveHW, renameTo);
  }

  Future<void> _exportIdentity(String name) async {
    final exportPass = await showExportPassphraseDialog(context, 'Backup Identity');
    if (exportPass == null || !mounted) return;
    try {
      await icfxService.stageBundlePassphrase(exportPass);
      final armored = await _runUnlocked(() => icfxService.exportIdentity(name));
      if (!mounted) return;
      // Default filename comes from icfx (<alias-or-name>.icid); the user can
      // still rename in the save dialog.
      final defaultName = await icfxService.identityBackupFilename(name);
      if (!mounted) return;
      final result = await fileChooserService.saveFile(
        'Backup Identity',
        defaultName,
        '',
        bytes: Uint8List.fromList(armored.codeUnits),
      );
      if (result.cancelled || !mounted) return;
      showSuccessDialog(context,'Identity backed up', result);
    } on FlugoException catch (e) {
      if (!mounted) return;
      unawaited(showMessageDialog(context, 'Backup Failed', '$e'));
    } finally {
      exportPass.fillRange(0, exportPass.length, 0);
    }
  }

  // Thin delegates — orchestration lives in profile_flow.dart so app.dart
  // doesn't carry the full export/import multi-step UX.
  Future<void> _exportProfile() => runExportProfileFlow(context, setStatus: _setStatus);

  Future<void> _importProfile() => runImportProfileFlow(
        context,
        setStatus: _setStatus,
        reinitializeAfterImport: _reinitializeAfterImport,
      );

  // _reinitializeAfterImport rebuilds every piece of state that an imported
  // profile may have changed: keychain availability (the imported config
  // might have set keystore=keychain on a machine where keychain isn't
  // configured the way it was on the source), key presence, identities,
  // contacts. Also re-runs _ensureUnlocked since default identity / keystore
  // preference / passphrase may all now differ.
  Future<void> _reinitializeAfterImport() async {
    if (!mounted) return;
    setState(() {
      _identities = [];
      _contacts = [];
      _selectedIdentityName = null;
      _useMyLock = false;
      _alsoSelf = false;
      _selectedContacts = [];
      _hasKeys = false;
    });
    // Drop any cached unlock — the imported config may point at a different
    // default identity or a different keystore type.
    try {
      await icfxService.lock();
    } on FlugoException {
      // Best-effort.
    }
    await _initialize();
  }

  Future<void> _showAddContactSheet() async {
    final theme = Theme.of(context);
    final isDesktop = Platform.isLinux || Platform.isMacOS || Platform.isWindows;
    // Cloud discovery is only offered when cloud is on AND signed in — the
    // same gate every cloud surface uses.
    var cloudReady = false;
    try {
      final st = jsonDecode(await cloudService.cloudUIState()) as Map<String, dynamic>;
      cloudReady = st['enabled'] == true && st['signed_in'] == true;
    } catch (_) {
      // Offline/misconfigured cloud just hides the tile.
    }
    if (!mounted) return;
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
            buildActionTile(ctx, theme, Icons.file_open, 'Import Lock', 'Import from a lock file', () {
              Navigator.pop(ctx);
              _importLockFileQuick();
            }),
            const SizedBox(height: 8),
            if (!isDesktop)
              buildActionTile(ctx, theme, Icons.qr_code_scanner, 'Scan QR Code', 'Scan QR code to import contact', () {
                Navigator.pop(ctx);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => LockQRScannerPage(
                      onImportLockQRPart: _controller.importLockQRPart,
                      onConfirmContactImport: _controller.confirmContactImport,
                      onRefresh: () async {
                        await _refreshContacts();
                      },
                    ),
                  ),
                );
              }),
            if (!isDesktop) const SizedBox(height: 8),
            buildActionTile(ctx, theme, Icons.edit, 'Manual', 'Enter contact details manually', () {
              Navigator.pop(ctx);
              showManualAddContactDialog(
                context,
                onAdd: _controller.addContact,
                onRefresh: _refreshContacts,
              );
            }),
            if (cloudReady) const SizedBox(height: 8),
            if (cloudReady)
              buildActionTile(ctx, theme, Icons.cloud_outlined, 'Search Cloud', 'Find published identities in the directory', () {
                Navigator.pop(ctx);
                showSearchCloudDialog(context, onRefresh: _refreshContacts);
              }),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ));
  }

  Future<void> _importLockFileQuick() async {
    final path = await fileChooserService.pickFile('Import Lock File');
    if (path == null || !mounted) return;
    try {
      final outcome = await _controller.importLockFile(path, '');
      if (!mounted) return;
      await handleImportOutcome(
        context,
        outcome,
        onConfirm: _controller.confirmContactImport,
        onStatus: (msg) async {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg)),
          );
        },
      );
      if (!mounted) return;
      await maybeOfferCloudInvite(context, outcome);
      if (mounted) await _refreshContacts();
    } on FlugoException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: $e')),
      );
    }
  }

  void _showSettingsSheet({int initialTab = 0}) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => SettingsSheet(
          initialTab: initialTab,
          hasKeys: _hasKeys,
          isLoading: _isLoading,
          contacts: _contacts,
          identities: _identities,
          scrollController: scrollController,
          onCreateKeys: () async {
            await _createKeys();
          },
          onRemoveIdentity: (name) async {
            await _removeIdentity(name);
          },
          onSetDefaultIdentity: (name) async {
            await _setDefaultIdentity(name);
          },
          onRevokeIdentity: _controller.revokeIdentity,
          onRotateIdentity: _controller.rotateIdentity,
          onConfirmContactImport: _controller.confirmContactImport,
          onEditIdentity: _controller.editIdentity,
          onToggleHWKey: _toggleHWKey,
          onImportIdentity: _importIdentity,
          onShowIdentity: _controller.showIdentity,
          onExportLock: _controller.exportLock,
          onExportLockQR: _controller.exportLockQR,
          onExportIdentity: _exportIdentity,
          onAddContact: _controller.addContact,
          onRemoveContact: _controller.removeContact,
          onEditContact: _controller.editContact,
          onShowContact: _controller.showContact,
          onExportContactLock: _controller.exportContactLock,
          onExportContactLockQR: _controller.exportContactLockQR,
          onImportLockFile: _controller.importLockFile,
          onImportLockQR: _controller.importLockQR,
          onImportLockQRPart: _controller.importLockQRPart,
          onGetSettings: _controller.getSettings,
          onSetSetting: _controller.setSetting,
          onExportProfile: _exportProfile,
          onImportProfile: _importProfile,
          groups: _groups,
          onAddGroup: _controller.addGroup,
          onEditGroup: _controller.editGroup,
          onRemoveGroup: _controller.removeGroup,
          onRefresh: () async {
            await _refreshIdentities();
            await _refreshContacts();
            await _refreshGroups();
            return (identities: _identities, contacts: _contacts, groups: _groups, hasKeys: _hasKeys);
          },
          showBell: _cloudEnabled,
          unseenNotifications: _unseenNotifCount,
          onOpenNotifications: () => _openNotificationsDrawer(context),
        ),
      ),
      // Cloud may have been toggled or logged in/out inside the sheet —
      // refresh the bell/badge state now rather than on the next 60s tick.
    ).whenComplete(_pollCloudNotices);
  }

  String get _actionButtonLabel {
    if (_selectedFilePath == null) return 'Submit';
    return _isDecryptMode ? 'Decrypt' : 'Encrypt';
  }

  // _finishWelcome is called when the onboarding wizard completes; it re-runs
  // initialization (the welcome flag is now set, so the gate falls through to
  // the normal unlock + home load).
  Future<void> _finishWelcome() async {
    if (!mounted) return;
    setState(() {
      _showWelcome = false;
      _isInitializing = true;
    });
    await _initialize();
    // The notices poll is suppressed while the wizard shows — fire it now
    // so the bells appear immediately after a cloud signup instead of on
    // the next 60s tick.
    await _pollCloudNotices();
  }

  @override
  Widget build(BuildContext context) {
    if (_showWelcome) {
      return WelcomeWizard(onDone: _finishWelcome);
    }
    final theme = Theme.of(context);
    return Scaffold(
      body: Column(
        children: [
          if (_isInitializing)
            const Expanded(
              child: Center(child: CircularProgressIndicator()),
            ),
          if (!_isInitializing)
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 32),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Logo
                            Image.asset('assets/logo.png', height: 80),
                            const SizedBox(height: 8),
                            Text(
                              'v0.1.0',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 28),

                            // Identity selector — the cloud notifications
                            // bell docks onto its right edge when cloud is
                            // on (same joined-segment style as the contact
                            // row's refresh/add buttons).
                            if (_hasKeys && _identities.isNotEmpty) ...[
                              IntrinsicHeight(
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      child: DropdownButtonFormField<String>(
                                        initialValue: _selectedIdentityName,
                                        decoration: InputDecoration(
                                          labelText: 'Identity',
                                          border: OutlineInputBorder(
                                            borderRadius: _cloudEnabled && _cloudSignedIn
                                                ? const BorderRadius.only(
                                                    topLeft: Radius.circular(4),
                                                    bottomLeft: Radius.circular(4),
                                                  )
                                                : BorderRadius.circular(4),
                                          ),
                                        ),
                                        items: _identities.map((id) {
                                          final name = id['name'] as String;
                                          final isDefault = id['is_default'] == true;
                                          return DropdownMenuItem(
                                            value: name,
                                            child: Text(isDefault ? '$name (default)' : name),
                                          );
                                        }).toList(),
                                        onChanged: (value) {
                                          setState(() => _selectedIdentityName = value);
                                        },
                                      ),
                                    ),
                                    if (_cloudEnabled && _cloudSignedIn)
                                      Container(
                                        decoration: BoxDecoration(
                                          border: Border(
                                            top: BorderSide(color: theme.colorScheme.outline),
                                            bottom: BorderSide(color: theme.colorScheme.outline),
                                          ),
                                        ),
                                        child: IconButton(
                                          onPressed: (_isLoading || _syncBusy) ? null : _homeSyncNow,
                                          icon: _syncBusy
                                              ? const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child: CircularProgressIndicator(strokeWidth: 2),
                                                )
                                              : const Icon(Icons.sync),
                                          tooltip: 'Sync now',
                                          constraints: const BoxConstraints(),
                                          padding: const EdgeInsets.all(8),
                                          style: IconButton.styleFrom(
                                            shape: const RoundedRectangleBorder(),
                                          ),
                                        ),
                                      ),
                                    if (_cloudEnabled && _cloudSignedIn)
                                      Container(
                                        decoration: BoxDecoration(
                                          border: Border(
                                            top: BorderSide(color: theme.colorScheme.outline),
                                            right: BorderSide(color: theme.colorScheme.outline),
                                            bottom: BorderSide(color: theme.colorScheme.outline),
                                          ),
                                          borderRadius: const BorderRadius.only(
                                            topRight: Radius.circular(4),
                                            bottomRight: Radius.circular(4),
                                          ),
                                        ),
                                        child: IconButton(
                                          onPressed: (_isLoading || _syncBusy)
                                              ? null
                                              : () => _openNotificationsDrawer(context),
                                          icon: Badge(
                                            isLabelVisible: _unseenNotifCount > 0,
                                            label: Text('$_unseenNotifCount'),
                                            child: const Icon(Icons.notifications_outlined),
                                          ),
                                          tooltip: 'Cloud notifications',
                                          constraints: const BoxConstraints(),
                                          padding: const EdgeInsets.all(8),
                                          style: IconButton.styleFrom(
                                            shape: const RoundedRectangleBorder(
                                              borderRadius: BorderRadius.only(
                                                topRight: Radius.circular(4),
                                                bottomRight: Radius.circular(4),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 20),
                            ],

                            // File drop target
                            DropTarget(
                              onDragEntered: (_) => setState(() => _isDragging = true),
                              onDragExited: (_) => setState(() => _isDragging = false),
                              onDragDone: (details) {
                                setState(() => _isDragging = false);
                                if (details.files.isNotEmpty) {
                                  _selectFile(details.files.first.path);
                                }
                              },
                              child: InkWell(
                                onTap: _pickFile,
                                borderRadius: BorderRadius.circular(12),
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(vertical: 24),
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: _isDragging
                                          ? theme.colorScheme.primary
                                          : theme.colorScheme.outlineVariant,
                                      width: _isDragging ? 2 : 1,
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    color: _isDragging
                                        ? theme.colorScheme.primary.withValues(alpha: 0.08)
                                        : null,
                                  ),
                                  child: Column(
                                    children: [
                                      Icon(
                                        _selectedFileName != null
                                            ? Icons.insert_drive_file
                                            : Icons.upload_file,
                                        size: 32,
                                        color: theme.colorScheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _selectedFileName ?? 'Select or Drop File',
                                        style: theme.textTheme.bodyMedium?.copyWith(
                                          color: _selectedFileName != null
                                              ? theme.colorScheme.onSurface
                                              : theme.colorScheme.onSurfaceVariant,
                                        ),
                                        textAlign: TextAlign.center,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),

                            // Contact multi-select. Uses dropdown_search for
                            // type-to-filter on a list that can grow large;
                            // the package shows all items on open and filters
                            // as the user types. Pick one or more contacts —
                            // age encrypts one file to all of them. The inline
                            // "Also encrypt to me" icon toggle (next to Add
                            // Contact) stacks the signer's own lock on top.
                            // Hidden when "Use my Lock" (self-only) is active.
                            // Clear button empties the selection.
                            if (!_isDecryptMode && !_useMyLock)
                              IntrinsicHeight(
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Expanded(
                                      child: DropdownSearch<String>.multiSelection(
                                        selectedItems: _selectedContacts,
                                        // Contacts AND groups, alphabetically.
                                        // A selected group is expanded to its
                                        // members by the backend at encrypt time.
                                        items: (filter, _) => _recipientItems,
                                        // Desktop: anchored menu popup that
                                        // sits below the trigger field. Mobile:
                                        // modal bottom sheet (slides up from
                                        // the bottom of the screen) — avoids
                                        // overlapping the surrounding form
                                        // fields on the tighter mobile layout.
                                        popupProps: Platform.isAndroid || Platform.isIOS
                                            ? MultiSelectionPopupProps.modalBottomSheet(
                                                showSearchBox: true,
                                                // Circular selection indicators
                                                // instead of the default square
                                                // checkboxes.
                                                checkBoxBuilder: (ctx, _, __, selected) =>
                                                    circleCheckbox(ctx, selected),
                                                itemBuilder: _recipientItemBuilder,
                                                searchFieldProps: const TextFieldProps(
                                                  autofocus: true,
                                                  decoration: InputDecoration(
                                                    hintText: 'Search contacts…',
                                                    prefixIcon: Icon(Icons.search),
                                                    border: OutlineInputBorder(),
                                                    isDense: true,
                                                  ),
                                                ),
                                              )
                                            : MultiSelectionPopupProps.menu(
                                                showSearchBox: true,
                                                checkBoxBuilder: (ctx, _, __, selected) =>
                                                    circleCheckbox(ctx, selected),
                                                itemBuilder: _recipientItemBuilder,
                                                // Cap the popup height so it
                                                // fits below the trigger field
                                                // instead of being auto-shifted
                                                // up to fit on screen.
                                                constraints: const BoxConstraints(maxHeight: 240),
                                                menuProps: const MenuProps(
                                                  align: MenuAlign.bottomStart,
                                                  margin: EdgeInsets.only(top: 4),
                                                ),
                                                searchFieldProps: const TextFieldProps(
                                                  autofocus: true,
                                                  decoration: InputDecoration(
                                                    hintText: 'Search contacts…',
                                                    prefixIcon: Icon(Icons.search),
                                                    border: OutlineInputBorder(),
                                                    isDense: true,
                                                  ),
                                                ),
                                              ),
                                        decoratorProps: DropDownDecoratorProps(
                                          decoration: InputDecoration(
                                            labelText: 'Select Contacts',
                                            border: OutlineInputBorder(
                                              borderRadius: _hasKeys
                                                  ? const BorderRadius.only(
                                                      topLeft: Radius.circular(4),
                                                      bottomLeft: Radius.circular(4),
                                                    )
                                                  : BorderRadius.circular(4),
                                            ),
                                          ),
                                        ),
                                        suffixProps: const DropdownSuffixProps(
                                          clearButtonProps: ClearButtonProps(isVisible: true),
                                        ),
                                        onSelected: (values) {
                                          setState(() {
                                            _selectedContacts = values;
                                            if (values.isNotEmpty) {
                                              _useMyLock = false;
                                            }
                                          });
                                        },
                                      ),
                                    ),
                                    if (_hasKeys) ...[
                                      // "Also encrypt to me" toggle (in the old
                                      // Refresh slot): non-exclusive — stacks
                                      // the signer's own lock on top of the
                                      // selected contacts. Distinct from the
                                      // "Use my Lock" self-only button below.
                                      Container(
                                        decoration: BoxDecoration(
                                          border: Border(
                                            top: BorderSide(color: Theme.of(context).colorScheme.outline),
                                            bottom: BorderSide(color: Theme.of(context).colorScheme.outline),
                                          ),
                                        ),
                                        child: IconButton(
                                          onPressed: _isLoading
                                              ? null
                                              : () => setState(() => _alsoSelf = !_alsoSelf),
                                          icon: Icon(_alsoSelf
                                              ? Icons.account_circle
                                              : Icons.account_circle_outlined),
                                          tooltip: 'Also encrypt to me',
                                          isSelected: _alsoSelf,
                                          color: _alsoSelf ? theme.colorScheme.primary : null,
                                          constraints: const BoxConstraints(),
                                          padding: const EdgeInsets.all(8),
                                          style: IconButton.styleFrom(
                                            shape: const RoundedRectangleBorder(),
                                            backgroundColor: _alsoSelf
                                                ? theme.colorScheme.primary.withValues(alpha: 0.15)
                                                : null,
                                          ),
                                        ),
                                      ),
                                      Container(
                                        decoration: BoxDecoration(
                                          border: Border(
                                            top: BorderSide(color: Theme.of(context).colorScheme.outline),
                                            right: BorderSide(color: Theme.of(context).colorScheme.outline),
                                            bottom: BorderSide(color: Theme.of(context).colorScheme.outline),
                                          ),
                                          borderRadius: const BorderRadius.only(
                                            topRight: Radius.circular(4),
                                            bottomRight: Radius.circular(4),
                                          ),
                                        ),
                                        child: IconButton(
                                          onPressed: _isLoading ? null : _showAddContactSheet,
                                          icon: const Icon(Icons.add),
                                          tooltip: 'Add Contact',
                                          constraints: const BoxConstraints(),
                                          padding: const EdgeInsets.all(8),
                                          style: IconButton.styleFrom(
                                            shape: const RoundedRectangleBorder(
                                              borderRadius: BorderRadius.only(
                                                topRight: Radius.circular(4),
                                                bottomRight: Radius.circular(4),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            if (!_isDecryptMode && !_useMyLock) const SizedBox(height: 20),

                            // Create Identity / Use my Lock (encrypt-to-self):
                            // self-ONLY, mutually exclusive with contacts (hides
                            // the Select Contacts field above).
                            if (!_isDecryptMode)
                              SizedBox(
                                width: double.infinity,
                                child: !_hasKeys
                                    ? OutlinedButton.icon(
                                        onPressed: _isLoading ? null : () async {
                                          try {
                                            await _createKeys();
                                          } catch (e) {
                                            if (!context.mounted) return;
                                            unawaited(showMessageDialog(context, 'Create Identity Failed', '$e'));
                                          }
                                        },
                                        style: OutlinedButton.styleFrom(
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          padding: const EdgeInsets.symmetric(vertical: 14),
                                        ),
                                        icon: const Icon(Icons.lock_open),
                                        label: const Text('Create Lock & Key'),
                                      )
                                    : OutlinedButton.icon(
                                        onPressed: _selectedContacts.isNotEmpty
                                            ? null
                                            : () => setState(() {
                                                _useMyLock = !_useMyLock;
                                                if (_useMyLock) {
                                                  _selectedContacts = [];
                                                }
                                              }),
                                        style: OutlinedButton.styleFrom(
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          padding: const EdgeInsets.symmetric(vertical: 14),
                                          backgroundColor: _useMyLock
                                              ? theme.colorScheme.primary.withValues(alpha: 0.15)
                                              : null,
                                        ),
                                        icon: const Icon(Icons.lock),
                                        label: const Text('Use my Lock'),
                                      ),
                              ),
                            if (!_isDecryptMode) const SizedBox(height: 28),

                            // Action button
                            SizedBox(
                              width: double.infinity,
                              child: FilledButton(
                                onPressed: (_selectedFilePath == null || _isLoading)
                                    ? null
                                    : _submit,
                                child: _isLoading
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      )
                                    : Text(_actionButtonLabel),
                              ),
                            ),
                            const SizedBox(height: 28),

                            // Settings gear icon (badged with waiting
                            // contact invites — tap lands on Settings as
                            // usual; the Contacts tab holds the requests).
                            Badge(
                              isLabelVisible: _unseenNotifCount > 0,
                              label: Text('$_unseenNotifCount'),
                              child: Container(
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  shape: BoxShape.circle,
                                ),
                                child: IconButton(
                                  onPressed: _showSettingsSheet,
                                  icon: const Icon(Icons.settings),
                                  tooltip: 'Settings',
                                  color: theme.colorScheme.onPrimary,
                                ),
                              ),
                            ),
                            const SizedBox(height: 20),

                            // Status message (dismissable via the X)
                            if (_statusMessage.isNotEmpty)
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: _isError
                                      ? theme.colorScheme.errorContainer
                                      : theme.colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _statusMessage,
                                        style: theme.textTheme.bodySmall?.copyWith(
                                          color: _isError
                                              ? theme.colorScheme.onErrorContainer
                                              : theme.colorScheme.onSurfaceVariant,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      icon: Icon(
                                        Icons.close,
                                        size: 18,
                                        color: _isError
                                            ? theme.colorScheme.onErrorContainer
                                            : theme.colorScheme.onSurfaceVariant,
                                      ),
                                      tooltip: 'Dismiss',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () => setState(() => _statusMessage = ''),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
