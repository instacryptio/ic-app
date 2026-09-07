import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../bridge/bridge.gen.dart';
import '../bridge/filechooser.dart';
import 'dialogs.dart' show showOverwriteConfirmDialog, showSuccessDialog, showTextPromptDialog;
import 'ic_share.dart'
    show animatedProgressIndicator, cleanBridgeError, icShareExpiryLabel, icShareHumanSize;
import 'onboarding/welcome_wizard.dart';
import 'plan_table.dart';
import 'sync_choice_screen.dart';
import 'sync_flow.dart';
import 'top_drawer.dart';
import 'webauthn_support.dart' show isMobileWebAuthnPlatform, mobileWebAuthnEnroll, platformWebAuthnSupported;

/// SettingsCloudTab is the app's cloud home: the master on/off switch, the
/// session (log in / log out), per-resource sync toggles, and Sync Now.
///
/// Master switch OFF hides everything cloud-related app-wide; the tab then
/// shows only the switch and a blurb. Turning it off deletes nothing.
class SettingsCloudTab extends StatefulWidget {
  const SettingsCloudTab({
    super.key,
    required this.hasKeys,
    required this.onError,
    required this.onStatus,
    this.onSynced,
  });

  /// Whether this device already has identities (skips the wizard's
  /// create-identity step when setting up cloud from here).
  final bool hasKeys;
  final void Function(String message) onError;

  /// Success/status messages (e.g. sync outcomes) — rendered by the sheet as
  /// the green banner, mirroring how onError feeds the red one.
  final void Function(String message) onStatus;

  /// Called after a sync settles so the UI re-reads the local stores a pull
  /// may have just updated (contacts/identities). Without this, a pulled
  /// contact only appears after an app restart.
  final Future<void> Function()? onSynced;

  @override
  State<SettingsCloudTab> createState() => _SettingsCloudTabState();
}

class _SettingsCloudTabState extends State<SettingsCloudTab> {
  Map<String, dynamic>? _state; // parsed CloudUIState
  bool _busy = false;
  bool _webAuthnSupported = false;
  List<Map<String, dynamic>> _hardwareKeys = [];
  List<Map<String, dynamic>> _sessions = [];
  String _sessionsError = '';

  // Inline login form.
  bool _loginOpen = false;
  final _emailCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  String _factor = '';
  String _tempToken = '';
  String _webauthnOptions = ''; // assertion options from a webauthn challenge

  // Last sync outcomes — surfaced through onStatus (the sheet's green banner).

  Timer? _uiRefresh;

  @override
  void initState() {
    super.initState();
    _reload();
    // Display freshness only (last-synced line, background outcomes) — the
    // sync engine itself lives in the Go backend.
    _uiRefresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && !_busy && !_loginOpen) _reload();
    });
  }

  @override
  void dispose() {
    _uiRefresh?.cancel();
    _emailCtrl.dispose();
    _pwCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    try {
      final raw = await cloudService.cloudUIState();
      final supported = await platformWebAuthnSupported();
      if (!mounted) return;
      setState(() {
        _state = jsonDecode(raw) as Map<String, dynamic>;
        _webAuthnSupported = supported;
      });
    } on FlugoException catch (e) {
      widget.onError('Cloud state: ${e.message}');
    }
    await _reloadHardwareKeys();
    // Independent of hardware-key/WebAuthn support — the Devices list must
    // load on every platform (the HW loader early-returns on mobile).
    await _reloadSessions();
  }

  Future<void> _reloadHardwareKeys() async {
    if (!_webAuthnSupported || !_enabled || !_signedIn) {
      if (mounted && _hardwareKeys.isNotEmpty) setState(() => _hardwareKeys = []);
      return;
    }
    try {
      final raw = await cloudService.webAuthnListKeys();
      if (!mounted) return;
      setState(() =>
          _hardwareKeys = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>());
    } on FlugoException {
      // Best-effort (offline etc.) — the section just shows no keys.
    }
  }

  Future<void> _reloadSessions() async {
    if (!_enabled || !_signedIn) {
      if (mounted && _sessions.isNotEmpty) setState(() => _sessions = []);
      return;
    }
    try {
      final raw = await cloudService.listCloudSessions();
      if (!mounted) return;
      setState(() {
        _sessions = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
        _sessionsError = '';
      });
    } on FlugoException {
      // Best-effort (offline etc.) — the Devices section just shows nothing.
    }
  }

  Future<bool> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      return true;
    } catch (e) {
      final msg = e is FlugoException ? e.message : e.toString();
      widget.onError(msg.replaceFirst('Exception: ', ''));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _enabled => (_state?['enabled'] as bool?) ?? false;
  bool get _signedIn => (_state?['signed_in'] as bool?) ?? false;

  @override
  Widget build(BuildContext context) {
    final st = _state;
    if (st == null) {
      // Same shape as the sibling tabs' loading state — the sheet gives the
      // tab content unbounded height, so no ListView/expanding widgets here.
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return Column(
      key: const ValueKey('cloud'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _masterSwitch(),
        if (_enabled && !_signedIn) ..._signedOutSection(),
        if (_enabled && _signedIn) ..._signedInSection(st),
      ],
    );
  }

  // Rounded full-width button style — identical to the Advanced tab's
  // Export/Import Profile buttons so the tabs read as one app.
  ButtonStyle get _buttonStyle => OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      );

  Widget _masterSwitch() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Instacrypt Cloud'),
          value: _enabled,
          onChanged: _busy
              ? null
              : (v) async {
                  final ok = await _run(() => cloudService.setCloudEnabled(v));
                  if (ok) await _reload();
                },
        ),
        if (!_enabled)
          Text(
            'Sync, backup, and contact discovery are hidden while cloud is off. '
            'Nothing is deleted — turn it back on anytime.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        const Divider(height: 24),
      ],
    );
  }

  // --- signed out -----------------------------------------------------------

  List<Widget> _signedOutSection() {
    if (_loginOpen) return [_loginForm()];
    final theme = Theme.of(context);
    return [
      Text(
        "You're not signed in.",
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _busy ? null : () => setState(() => _loginOpen = true),
        icon: const Icon(Icons.login),
        label: const Text('Log In'),
        style: _buttonStyle,
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _busy ? null : _launchCloudSetup,
        icon: const Icon(Icons.cloud_outlined),
        label: const Text('Set Up With Cloud (New Account)'),
        style: _buttonStyle,
      ),
    ];
  }

  Future<void> _launchCloudSetup() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => WelcomeWizard(
        cloudSetupOnly: true,
        skipIdentity: widget.hasKeys,
        onDone: () async {
          if (mounted) Navigator.of(context).pop();
        },
      ),
    ));
    await _reload();
  }

  Widget _loginForm() {
    final theme = Theme.of(context);
    final challenged = _factor.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!challenged) ...[
          TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            style: theme.textTheme.bodyMedium,
            decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pwCtrl,
            obscureText: true,
            style: theme.textTheme.bodyMedium,
            decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder(), isDense: true),
          ),
        ],
        if (challenged) ...[
          Text(
            _factor == 'email'
                ? 'Enter the code we emailed you.'
                : _factor == 'totp'
                    ? 'Enter the code from your authenticator (or a recovery code).'
                    : _webAuthnSupported
                        ? 'This account is protected by a hardware security key.'
                        : "Hardware-key sign-in isn't supported on this device — use the desktop app or CLI.",
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          if (_factor != 'webauthn')
            TextField(
              controller: _codeCtrl,
              style: theme.textTheme.bodyMedium,
              decoration: const InputDecoration(labelText: 'Code', border: OutlineInputBorder(), isDense: true),
            ),
        ],
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _busy ? null : _cancelLogin,
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _busy || (_factor == 'webauthn' && !_webAuthnSupported)
                  ? null
                  : challenged
                      ? (_factor == 'webauthn' ? _verifyLoginWebAuthn : _verifyLoginCode)
                      : _doLogin,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(challenged
                      ? (_factor == 'webauthn' ? 'Use Security Key' : 'Verify')
                      : 'Log In'),
            ),
          ],
        ),
      ],
    );
  }

  void _cancelLogin() {
    setState(() {
      _loginOpen = false;
      _factor = '';
      _tempToken = '';
      _pwCtrl.clear();
      _codeCtrl.clear();
    });
  }

  Future<void> _doLogin() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty || _pwCtrl.text.isEmpty) {
      widget.onError('Enter your email and password.');
      return;
    }
    final ok = await _run(() async {
      await sendCloudPassword(_pwCtrl.text);
      final challenge = await cloudService.logIn(email);
      if (challenge.isEmpty) {
        _factor = '';
        return;
      }
      final parsed = jsonDecode(challenge) as Map<String, dynamic>;
      _factor = (parsed['factor'] as String?) ?? '';
      _tempToken = (parsed['temp_token'] as String?) ?? '';
      _webauthnOptions = parsed['webauthn'] != null ? jsonEncode(parsed['webauthn']) : '';
    });
    if (!ok) return;
    if (_factor.isEmpty) {
      _cancelLogin();
      await _reload();
      await _maybePromptSyncChoice();
      return;
    }
    setState(() {}); // show the code / security-key step
  }


  Future<void> _verifyLoginCode() async {
    final ok = await _run(() async {
      if (_factor == 'email') {
        await cloudService.logInEmail(_tempToken, _codeCtrl.text.trim());
        return;
      }
      await cloudService.logInTOTP(_tempToken, _codeCtrl.text.trim());
    });
    if (!ok) return;
    _cancelLogin();
    await _reload();
    await _maybePromptSyncChoice();
  }

  Future<void> _verifyLoginWebAuthn() async {
    final ok = await webAuthnAssert(context, _run, _tempToken, _webauthnOptions, onError: widget.onError);
    if (!ok) return;
    _cancelLogin();
    await _reload();
    await _maybePromptSyncChoice();
  }

  // _maybePromptSyncChoice re-presents the "What should sync?" choice after a
  // login when a prior sign-out marked it pending — pre-filled with the last
  // choices. Nothing auto-syncs until it's confirmed (backend gates on
  // cloud_sync_choice_pending); confirming clears the gate via setSyncTiers and
  // runs the first sync. Cancelling leaves sync paused until the user picks.
  Future<void> _maybePromptSyncChoice() async {
    final st = _state;
    if (st == null ||
        st['signed_in'] != true ||
        st['enabled'] != true ||
        st['sync_choice_pending'] != true) {
      return;
    }
    if (!mounted) return;
    var confirmed = false;
    await Navigator.of(context).push<void>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (ctx) => SyncChoiceScreen(
        initialContacts: (st['sync_contacts'] as bool?) ?? true,
        initialSettings: (st['sync_settings'] as bool?) ?? true,
        initialIdentities: (st['sync_identities'] as bool?) ?? false,
        subtitle:
            'Choose what syncs to this device. Stored encrypted — the server only ever sees ciphertext.',
        onCancel: () => Navigator.of(ctx).pop(),
        onConfirm: (contacts, settings, identities) async {
          final ok = await _run(() => cloudService.setSyncTiers(contacts, settings, identities));
          if (!ok) return;
          confirmed = true;
          if (ctx.mounted) Navigator.of(ctx).pop();
        },
      ),
    ));
    if (!mounted) return;
    await _reload();
    if (confirmed && mounted) await _syncNow();
  }

  // --- signed in --------------------------------------------------------------

  List<Widget> _signedInSection(Map<String, dynamic> st) {
    final theme = Theme.of(context);
    final tier = (st['tier'] as String?) ?? '';
    final vip = st['vip'] == true;
    final twoFactor = (st['two_factor'] as String?) ?? '';
    return [
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text('Signed in as ${st['email']}'),
        subtitle: Text([
          if (tier.isNotEmpty) 'Plan: $tier${vip ? ' (VIP)' : ''}',
          if (twoFactor.isNotEmpty) '2FA: ${twoFactor == 'none' ? 'off' : twoFactor}',
        ].join('   ')),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: _busy ? null : _showPlanDialog,
              child: const Text('Plan…'),
            ),
            TextButton(
              onPressed: _busy ? null : _logout,
              child: const Text('Log Out'),
            ),
          ],
        ),
      ),
      const Divider(height: 24),
      OutlinedButton.icon(
        onPressed: _busy ? null : _showSharedFilesSheet,
        icon: const Icon(Icons.folder_shared_outlined),
        label: const Text('Manage Shared Files'),
        style: _buttonStyle,
      ),
      const Divider(height: 24),
      // What-syncs choices are set once and rarely revisited — collapsed by
      // default; the summary line shows the current selection at a glance.
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        initiallyExpanded: false,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text('Sync', style: theme.textTheme.titleSmall),
        subtitle: Text(
          _syncSummary(st),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        children: [
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: (st['sync_contacts'] as bool?) ?? false,
            onChanged: _busy ? null : (v) => _setTiers(contacts: v ?? false),
            title: const Text('Contacts & Groups'),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: (st['sync_settings'] as bool?) ?? false,
            onChanged: _busy ? null : (v) => _setTiers(settings: v ?? false),
            title: const Text('Settings'),
          ),
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: (st['sync_identities'] as bool?) ?? false,
            onChanged: _busy ? null : (v) => _setTiers(identities: v ?? false),
            title: const Text('Identities (Keys)'),
            subtitle: const Text('Asks for your cloud password at sync time'),
          ),
        ],
      ),
      const SizedBox(height: 8),
      SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: const Text('Auto-sync'),
        subtitle: const Text('Also syncs instantly when another device pushes changes'),
        value: ((st['auto_sync_minutes'] as num?)?.toInt() ?? 0) > 0,
        onChanged: _busy ? null : (v) => _setAutoSync(v ? 10 : 0),
      ),
      if (((st['auto_sync_minutes'] as num?)?.toInt() ?? 0) > 0)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: const Text('Interval'),
          trailing: DropdownButton<int>(
            value: _normalizedInterval((st['auto_sync_minutes'] as num?)?.toInt() ?? 10),
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 5, child: Text('5 min')),
              DropdownMenuItem(value: 10, child: Text('10 min')),
              DropdownMenuItem(value: 30, child: Text('30 min')),
              DropdownMenuItem(value: 60, child: Text('60 min')),
            ],
            onChanged: _busy ? null : (v) => _setAutoSync(v ?? 10),
          ),
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _busy ? null : _syncNow,
        icon: const Icon(Icons.sync),
        label: const Text('Sync Now'),
        style: _buttonStyle,
      ),
      if (_lastSyncLine(st) != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            _lastSyncLine(st)!,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _busy ? null : _rekeyCloudData,
        icon: const Icon(Icons.lock_reset),
        label: const Text('Re-key Cloud Data'),
        style: _buttonStyle,
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          "Fixes cloud data another device reports as “sealed to a key that isn’t "
          "on this device” after you changed identities. Run it here, where your real "
          'data lives.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ),
      const Divider(height: 24),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text('Two-Factor Sign-In', style: theme.textTheme.titleSmall),
      ),
      ..._twoFactorSection(twoFactor, theme),
      const Divider(height: 24),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text('Devices', style: theme.textTheme.titleSmall),
      ),
      ..._devicesSection(theme),
      const Divider(height: 24),
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text('Danger Zone', style: theme.textTheme.titleSmall),
      ),
      Text(
        'Deleting your account schedules it for permanent removal in 30 days '
        'and signs out every device. To cancel, just log in again on any '
        'device before then.',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _busy ? null : _deleteAccount,
        icon: Icon(Icons.delete_forever, color: theme.colorScheme.error),
        label: Text('Delete Account', style: TextStyle(color: theme.colorScheme.error)),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: theme.colorScheme.error),
        ),
      ),
    ];
  }

  // Devices: every live login on this account. Logging one out frees a slot
  // toward the account's device limit and forces that device to sign in
  // again. Errors stay in this section — never the main status bar.
  List<Widget> _devicesSection(ThemeData theme) {
    if (_sessions.isEmpty) {
      return [
        Text(
          'No device list available right now.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ];
    }
    return [
      for (final s in _sessions)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  (s['device'] as String?)?.isNotEmpty == true ? s['device'] as String : '(unnamed device)',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (s['current'] == true)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Text(
                    'this device',
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
            ],
          ),
          subtitle: Text(_sessionActivityLine(s)),
          trailing: IconButton(
            icon: const Icon(Icons.logout, size: 20),
            tooltip: 'Log this device out',
            onPressed: _busy ? null : () => _confirmRevokeSession(s),
          ),
        ),
      if (_sessionsError.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            _sessionsError,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
          ),
        ),
    ];
  }

  String _sessionActivityLine(Map<String, dynamic> s) {
    final last = DateTime.tryParse((s['last_active'] as String?) ?? '');
    if (last == null) return 'Signed in';
    final d = DateTime.now().difference(last.toLocal());
    if (d.inMinutes < 2) return 'Active just now';
    if (d.inHours < 1) return 'Active ${d.inMinutes}m ago';
    if (d.inDays < 1) return 'Active ${d.inHours}h ago';
    return 'Active ${d.inDays}d ago';
  }

  void _confirmRevokeSession(Map<String, dynamic> s) {
    final isCurrent = s['current'] == true;
    final name = (s['device'] as String?)?.isNotEmpty == true ? s['device'] as String : 'this device';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isCurrent ? 'Log out this device?' : 'Log out "$name"?'),
        content: Text(isCurrent
            ? 'You\'ll be signed out here and need to log in again.'
            : 'That device is signed out immediately and needs to log in again. This frees one device slot.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                await cloudService.revokeCloudSession(s['id'] as String);
                if (!mounted) return;
                if (isCurrent) {
                  await _reload(); // signed out — the tab flips to login
                  return;
                }
                await _reloadSessions();
              } catch (e) {
                if (!mounted) return;
                setState(() => _sessionsError = cleanBridgeError(e));
              }
            },
            child: const Text('Log Out'),
          ),
        ],
      ),
    );
  }

  // _syncSummary renders the collapsed Sync tile's one-line selection
  // summary, e.g. "Contacts, Settings" or "Nothing selected".
  String _syncSummary(Map<String, dynamic> st) {
    final on = <String>[
      if ((st['sync_contacts'] as bool?) ?? false) 'Contacts & Groups',
      if ((st['sync_settings'] as bool?) ?? false) 'Settings',
      if ((st['sync_identities'] as bool?) ?? false) 'Identities',
    ];
    return on.isEmpty ? 'Nothing selected' : on.join(', ');
  }

  void _showSharedFilesSheet() {
    showTopDrawer<void>(context, builder: (_) => const _SharedFilesSheet());
  }

  // The server reports the ACTIVE factor (webauthn > totp > email > none);
  // offer the actions that make sense for the current one.
  List<Widget> _twoFactorSection(String twoFactor, ThemeData theme) {
    switch (twoFactor) {
      case 'totp':
        return [
          Text(
            'Authenticator app is on (it outranks email codes while enrolled).',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _disableTotp,
            icon: const Icon(Icons.phonelink_erase),
            label: const Text('Disable Authenticator App'),
            style: _buttonStyle,
          ),
        ];
      case 'webauthn':
        return [
          Text(
            _webAuthnSupported
                ? 'A hardware key protects sign-in (it outranks all other factors).'
                : 'A hardware key protects sign-in. Manage keys with the desktop app or CLI.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          ..._hardwareKeysSection(theme),
        ];
      case 'email':
        return [
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Email codes'),
            subtitle: const Text('A 6-digit code is emailed at every sign-in'),
            value: true,
            onChanged: _busy ? null : (v) => _setEmailFactor(v),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _setupTotp,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Set Up Authenticator App'),
            style: _buttonStyle,
          ),
          ..._hardwareKeysSection(theme),
        ];
      default: // none (or unknown/offline)
        return [
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Email codes'),
            subtitle: const Text('A 6-digit code is emailed at every sign-in'),
            value: false,
            onChanged: _busy ? null : (v) => _setEmailFactor(v),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _setupTotp,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Set Up Authenticator App'),
            style: _buttonStyle,
          ),
          ..._hardwareKeysSection(theme),
        ];
    }
  }

  // Hardware security keys (FIDO2) — desktop only; mobile builds hide it.
  List<Widget> _hardwareKeysSection(ThemeData theme) {
    if (!_webAuthnSupported) return [];
    return [
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text('Hardware Keys', style: theme.textTheme.titleSmall),
      ),
      for (final k in _hardwareKeys)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.usb, size: 20),
          title: Text((k['label'] as String?) ?? '(unnamed)'),
          subtitle: Text('Added ${((k['created_at'] as String?) ?? '').split('T').first}'),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            onPressed: _busy ? null : () => _removeHardwareKey(k),
          ),
        ),
      OutlinedButton.icon(
        onPressed: _busy ? null : _addHardwareKey,
        icon: const Icon(Icons.usb),
        label: const Text('Add Hardware Key'),
        style: _buttonStyle,
      ),
    ];
  }

  Future<void> _addHardwareKey() async {
    final label = await showTextPromptDialog(
      context,
      title: 'Add Hardware Key',
      label: 'Name',
      hint: "A name for this key (e.g. 'yubikey-blue')",
    );
    if (label == null || label.trim().isEmpty || !mounted) return;
    if (isMobileWebAuthnPlatform) {
      // Native OS attestation ceremony (tap + UV) — no PIN prompt.
      final ok = await _run(() => mobileWebAuthnEnroll(context, label.trim()));
      if (!ok) return;
      widget.onStatus('Hardware key "${label.trim()}" added — sign-ins now require it.');
      await _reload();
      return;
    }
    final pin = await showTextPromptDialog(
      context,
      title: 'Security Key PIN',
      label: 'PIN',
      hint: 'Plug the key in first',
      obscure: true,
    );
    if (pin == null || pin.isEmpty || !mounted) return;
    final ok = await withTouchDialog(context, _run, () async {
      await sendSecurityKeyPIN(pin);
      await cloudService.webAuthnAddKey(label.trim());
    });
    if (!ok) return;
    widget.onStatus('Hardware key "${label.trim()}" added — sign-ins now require it.');
    await _reload();
  }

  Future<void> _removeHardwareKey(Map<String, dynamic> key) async {
    final pw = await showTextPromptDialog(
      context,
      title: 'Cloud password',
      label: 'Password',
      hint: 'Needed to remove a hardware key',
      obscure: true,
    );
    if (pw == null || pw.isEmpty || !mounted) return;
    final ok = await _run(() async {
      await sendCloudPassword(pw);
      await cloudService.webAuthnRemoveKey((key['id'] as String?) ?? '');
    });
    if (!ok) return;
    widget.onStatus('Hardware key "${(key['label'] as String?) ?? ''}" removed.');
    await _reload();
  }

  Future<void> _setEmailFactor(bool on) async {
    // Turning email 2FA OFF is a security downgrade, so the server requires the
    // cloud password to be re-verified (mirrors hardware-key removal). Enabling
    // needs no re-auth (address ownership was proven at signup).
    if (!on) {
      final pw = await showTextPromptDialog(
        context,
        title: 'Cloud password',
        label: 'Password',
        hint: 'Needed to turn off email codes',
        obscure: true,
      );
      if (pw == null || pw.isEmpty || !mounted) return;
      final ok = await _run(() async {
        await sendCloudPassword(pw);
        await cloudService.setEmailTwoFactor(false);
      });
      if (!ok) return;
      widget.onStatus('Email two-factor sign-in is off.');
      await _reload();
      return;
    }
    final ok = await _run(() => cloudService.setEmailTwoFactor(true));
    if (!ok) return;
    widget.onStatus(
        'Email two-factor sign-in is on — sign-ins now need an emailed code.');
    await _reload();
  }

  Future<void> _setupTotp() async {
    String setupJSON = '';
    final ok = await _run(() async {
      setupJSON = await cloudService.totpSetup();
    });
    if (!ok || !mounted) return;
    final setup = jsonDecode(setupJSON) as Map<String, dynamic>;
    final recoveryJSON = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TotpEnrollDialog(
        qrPngB64: (setup['qr_png_b64'] as String?) ?? '',
        otpauthURL: (setup['otpauth_url'] as String?) ?? '',
      ),
    );
    if (recoveryJSON == null || !mounted) return; // canceled — nothing enrolled
    final codes = (jsonDecode(recoveryJSON) as List<dynamic>).cast<String>();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RecoveryCodesDialog(codes: codes),
    );
    widget.onStatus('Authenticator app is on — sign-ins now need a code from your app.');
    await _reload();
  }

  Future<void> _disableTotp() async {
    final result = await showDialog<({String password, String code})>(
      context: context,
      builder: (_) => const _TotpDisableDialog(),
    );
    if (result == null) return;
    final ok = await _run(() async {
      await sendCloudPassword(result.password);
      await cloudService.totpDisable(result.code);
    });
    if (!ok) return;
    widget.onStatus('Authenticator app is off.');
    await _reload();
  }

  Future<void> _setTiers({bool? contacts, bool? settings, bool? identities}) async {
    final st = _state!;
    final ok = await _run(() => cloudService.setSyncTiers(
          contacts ?? (st['sync_contacts'] as bool? ?? false),
          settings ?? (st['sync_settings'] as bool? ?? false),
          identities ?? (st['sync_identities'] as bool? ?? false),
        ));
    if (ok) await _reload();
  }

  Future<void> _logout() async {
    final ok = await _run(() => cloudService.logout());
    if (ok) await _reload();
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
          'Your account will be scheduled for permanent deletion in 30 days '
          'and every device will be signed out. To cancel, just log in again '
          'on any device before the deadline.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep Account'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete Account'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final pw = await showTextPromptDialog(
      context,
      title: 'Confirm your password',
      label: 'Password',
      hint: 'Needed to schedule account deletion',
      obscure: true,
    );
    if (pw == null || pw.isEmpty || !mounted) return;
    final ok = await _run(() async {
      await sendCloudPassword(pw);
      await cloudService.requestAccountDeletion();
    });
    if (!ok) return;
    widget.onStatus(
        'Account deletion scheduled. Log in on any device within 30 days to cancel it.');
    await _reload();
  }

  Future<void> _showPlanDialog() async {
    await showDialog<void>(
      context: context,
      builder: (_) => const _PlanDialog(),
    );
    // The tier may have changed (upgrade/cancel) — refresh the account line.
    await _reload();
  }

  Future<void> _setAutoSync(int minutes) async {
    final ok = await _run(() => cloudService.setAutoSyncMinutes(minutes));
    if (ok) await _reload();
  }

  // 5/10/30/60 are the offered choices; snap odd config values to the nearest.
  int _normalizedInterval(int m) {
    const choices = [5, 10, 30, 60];
    var best = choices.first;
    for (final c in choices) {
      if ((m - c).abs() < (m - best).abs()) best = c;
    }
    return best;
  }

  String? _lastSyncLine(Map<String, dynamic> st) {
    final at = (st['last_sync_at'] as String?) ?? '';
    if (at.isEmpty) return null;
    final t = DateTime.tryParse(at)?.toLocal();
    if (t == null) return null;
    final delta = DateTime.now().difference(t);
    final when = delta.inSeconds < 60
        ? 'just now'
        : delta.inMinutes < 60
            ? '${delta.inMinutes}m ago'
            : delta.inHours < 24
                ? '${delta.inHours}h ago'
                : '${delta.inDays}d ago';
    final err = (st['last_sync_error'] as String?) ?? '';
    if (err.isNotEmpty) return 'Last sync $when — $err';
    final summary = (st['last_sync_summary'] as String?) ?? '';
    if (summary.isEmpty) return 'Last synced $when';
    return 'Last synced $when — $summary';
  }

  // --- sync -------------------------------------------------------------------

  // The full interactive sync flow lives in sync_flow.dart (shared with the
  // home-screen sync icon — one code path).
  Future<void> _syncNow() async {
    await runCloudSyncFlow(
      context,
      onStatus: widget.onStatus,
      onError: widget.onError,
      run: _run,
      webAuthnSupported: _webAuthnSupported,
    );
    // A pull may have updated the local contact/identity stores — re-read them
    // so newly synced contacts show without an app restart.
    await widget.onSynced?.call();
  }

  // _rekeyCloudData re-seals every self-lock cloud resource to the current
  // identity from THIS device's data — the repair for cloud blobs left sealed to
  // a superseded key after an identity change (delete-then-recreate). Overwrites
  // the cloud copy with this device's, so it's a deliberate, confirmed action.
  Future<void> _rekeyCloudData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Re-key cloud data?'),
        content: const Text(
          "Re-seals your cloud contacts, settings, groups and notifications to your "
          "current identity using THIS device's copy — the fix when another device "
          "reports them “sealed to a key that isn’t on this device.”\n\n"
          'Run this on the device that has your real data; it overwrites the cloud copy.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Re-key')),
        ],
      ),
    );
    if (ok != true) return;
    final done = await _run(() async {
      final msg = await icfxService.rekeyCloudData();
      widget.onStatus(msg);
    });
    if (done) await widget.onSynced?.call();
  }
}

/// _TotpEnrollDialog shows the enrollment QR + secret and confirms the first
/// live code. Pops with the recovery-codes JSON on success, null on cancel
/// (nothing is enrolled until the code confirms).
class _TotpEnrollDialog extends StatefulWidget {
  const _TotpEnrollDialog({required this.qrPngB64, required this.otpauthURL});

  final String qrPngB64;
  final String otpauthURL;

  @override
  State<_TotpEnrollDialog> createState() => _TotpEnrollDialogState();
}

class _TotpEnrollDialogState extends State<_TotpEnrollDialog> {
  final _codeCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final recovery = await cloudService.totpConfirm(_codeCtrl.text.trim());
      if (mounted) Navigator.of(context).pop(recovery);
    } catch (e) {
      final msg = e is FlugoException ? e.message : e.toString();
      if (mounted) {
        setState(() {
          _error = msg.replaceFirst('Exception: ', '');
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Set Up Authenticator App'),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Scan with your authenticator app, then enter the 6-digit code it shows.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              if (widget.qrPngB64.isNotEmpty)
                Center(
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(8),
                    child: Image.memory(
                      base64Decode(widget.qrPngB64),
                      width: 220,
                      height: 220,
                      filterQuality: FilterQuality.none,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              ExpansionTile(
                title: Text("Can't scan?", style: theme.textTheme.bodySmall),
                tilePadding: EdgeInsets.zero,
                shape: const Border(),
                collapsedShape: const Border(),
                children: [
                  SelectableText(widget.otpauthURL, style: theme.textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _codeCtrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '6-digit code', border: OutlineInputBorder(), isDense: true),
                onSubmitted: (_) => _confirm(),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Confirm'),
        ),
      ],
    );
  }
}

/// _RecoveryCodesDialog shows the one-time recovery codes. They are not
/// retrievable later, so it can't be dismissed by tapping outside.
class _RecoveryCodesDialog extends StatelessWidget {
  const _RecoveryCodesDialog({required this.codes});

  final List<String> codes;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Recovery Codes'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Save these somewhere safe — each works once if you lose your '
              'authenticator, and they cannot be shown again.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SelectableText(
              codes.join('\n'),
              style: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("I've saved them"),
        ),
      ],
    );
  }
}

/// _TotpDisableDialog collects the cloud password + a live (or recovery) code.
// _PlanDialog shows the account's plan (live server-reported limits — nothing
// hardcoded) with upgrade/cancel actions. Payment happens in the browser via
// the provider checkout URL; Refresh re-pulls after the webhook lands. All
// errors render inline in the dialog.
class _PlanDialog extends StatefulWidget {
  const _PlanDialog();

  @override
  State<_PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends State<_PlanDialog> {
  Map<String, dynamic>? _info;
  List<Map<String, dynamic>> _catalog = const [];
  bool _loading = true;
  bool _busy = false;
  String _error = '';
  String _notice = '';
  // Payment URL of the last checkout — always shown with a copy button so
  // the user can reach the payment page even if the browser hand-off fails.
  String _payURL = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final results = await Future.wait([
        cloudService.planInfo(),
        cloudService.planCatalog(),
      ]);
      if (!mounted) return;
      setState(() {
        _info = jsonDecode(results[0]) as Map<String, dynamic>;
        _catalog = (jsonDecode(results[1]) as List)
            .cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = cleanBridgeError(e);
        _loading = false;
      });
    }
  }

  Future<void> _upgrade(String tier) async {
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
      _payURL = '';
    });
    try {
      final url = await cloudService.upgradePlan(tier);
      // openCheckoutUrl enforces https-only; a non-https/unparseable URL from a
      // compromised billing server returns false (not launched) → the UI falls
      // back to "couldn't open — use Copy Link".
      final opened = await openCheckoutUrl(url);
      if (!mounted) return;
      setState(() {
        _payURL = url;
        _notice = opened
            ? 'Complete the payment in your browser, then hit Refresh.'
            : 'Couldn\'t open your browser — copy the payment link below and open it manually.';
      });
    } catch (e) {
      if (!mounted) return;
      // The server found (and adopted) a live subscription — not an error:
      // refresh so the user simply sees their current plan.
      if (e.toString().contains('already_subscribed')) {
        setState(() => _notice = 'You already have an active subscription — here is your current plan.');
        await _load();
        return;
      }
      setState(() => _error = cleanBridgeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyPayURL() async {
    final item = DataWriterItem();
    item.add(Formats.plainText(_payURL));
    await SystemClipboard.instance?.write([item]);
    if (!mounted) return;
    setState(() => _notice = 'Payment link copied.');
  }

  // _changeTier swaps the existing subscription's tier in place. Unlike the
  // checkout path there is no payment page in between — billing happens
  // immediately with proration — so every change confirms first.
  Future<void> _changeTier(String tier, {required bool isUpgrade}) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${isUpgrade ? 'Upgrade' : 'Downgrade'} to ${_tierLabel(tier)}?'),
        content: Text(isUpgrade
            ? 'Takes effect immediately; you\'ll be charged the prorated difference.'
            : 'Takes effect immediately; the difference is credited toward future invoices.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep Current Plan'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(isUpgrade ? 'Upgrade' : 'Downgrade'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
      _payURL = '';
    });
    try {
      await cloudService.changePlan(tier);
      if (!mounted) return;
      setState(() => _notice = 'Plan change requested — hit Refresh once it\'s confirmed.');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = cleanBridgeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelPlan() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel plan?'),
        content: const Text(
          'Your subscription will not renew and the account downgrades to Free at the end of the billing period.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep Plan'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Cancel Plan'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
      _payURL = '';
    });
    try {
      await cloudService.cancelPlan();
      if (!mounted) return;
      setState(() => _notice =
          'Cancellation scheduled — your plan stays active until the end of the billing period.');
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = cleanBridgeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resumePlan() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resume subscription?'),
        content: const Text(
          'The scheduled cancellation is removed and your subscription renews as usual.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Keep Cancellation'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Resume'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = '';
      _notice = '';
      _payURL = '';
    });
    try {
      await cloudService.resumePlan();
      if (!mounted) return;
      setState(() => _notice = 'Subscription resumed — it renews as usual.');
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = cleanBridgeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _tierLabel(String tier) {
    if (tier.isEmpty) return 'Unknown';
    return tier[0].toUpperCase() + tier.substring(1);
  }

  List<Widget> _content(ThemeData theme) {
    final info = _info!;
    final tier = (info['tier'] as String?) ?? '';
    final vip = info['vip'] == true;
    final paid = tier.isNotEmpty && tier != 'free';
    final subStatus = (info['sub_status'] as String?) ?? '';
    final renews = (info['renews_at'] as String?) ?? '';
    final cancelPending = info['sub_cancel_pending'] == true;
    final unknownTier =
        paid && !_catalog.any((e) => e['tier'] == tier);
    // A live subscription changes tiers in place; without one (free, or a
    // comped paid tier with no subscription) checkout is the safe path.
    final inPlace = subStatus == 'active' || subStatus == 'past_due';

    return [
      Row(children: [
        Text('Current plan: ${_tierLabel(tier)}', style: theme.textTheme.titleSmall),
        if (vip) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'VIP',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onPrimaryContainer,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ]),
      if (subStatus.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            'Subscription: $subStatus'
            '${renews.isNotEmpty ? (cancelPending ? ' · cancels $renews' : ' · renews $renews') : ''}',
            style: theme.textTheme.bodySmall,
          ),
        ),
      const SizedBox(height: 12),
      if (_catalog.isNotEmpty)
        PlanTable(
          catalog: _catalog,
          mode: PlanTableMode.manage,
          highlightTier: tier.isEmpty ? 'free' : tier,
          busy: _busy,
          // VIP already has every feature — nothing to buy, so no footer.
          onSelect: vip
              ? null
              : (t, isUpgrade) {
                  if (!inPlace) {
                    _upgrade(t);
                    return;
                  }
                  _changeTier(t, isUpgrade: isUpgrade);
                },
        ),
      if (vip)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'VIP access — all Ultimate features included.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      if (unknownTier)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            'Plan changes for this plan aren\'t available in this app version — please update the app.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      if (_catalog.isNotEmpty && !unknownTier && !vip)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            inPlace
                ? 'Plan changes are immediate and prorated.'
                : 'Upgrading opens the payment page in your browser.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      if (inPlace && cancelPending) ...[
        const SizedBox(height: 8),
        Text(
          'Cancellation scheduled — the plan downgrades to Free'
          '${renews.isNotEmpty ? ' on $renews' : ' at the end of the billing period'}.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        TextButton(
          onPressed: _busy ? null : _resumePlan,
          child: const Text('Resume subscription'),
        ),
      ],
      if (inPlace && !cancelPending) ...[
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : _cancelPlan,
          child: Text('Cancel plan', style: TextStyle(color: theme.colorScheme.error)),
        ),
      ],
      // A paid tier with no live subscription (comped account, or a row the
      // provider hasn't reported yet) has nothing to self-service-cancel.
      if (paid && !inPlace) ...[
        const SizedBox(height: 8),
        Text(
          'This plan has no self-service subscription to manage.',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Plan'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (!_loading && _info != null) ..._content(theme),
            if (_notice.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _notice,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            if (_payURL.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: TextButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('Copy Link'),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  onPressed: _copyPayURL,
                ),
              ),
            if (_error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy || _loading ? null : _load,
          child: const Text('Refresh'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _TotpDisableDialog extends StatefulWidget {
  const _TotpDisableDialog();

  @override
  State<_TotpDisableDialog> createState() => _TotpDisableDialogState();
}

class _TotpDisableDialogState extends State<_TotpDisableDialog> {
  final _pwCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();

  @override
  void dispose() {
    _pwCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop((password: _pwCtrl.text, code: _codeCtrl.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Disable Authenticator App'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _pwCtrl,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Cloud password', border: OutlineInputBorder(), isDense: true),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _codeCtrl,
            decoration: const InputDecoration(
              labelText: 'Authenticator or recovery code',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Disable')),
      ],
    );
  }
}


/// _SharedFilesSheet lists the account's cloud shares with delete. All
/// errors render inline in the sheet (never the main status bar).
class _SharedFilesSheet extends StatefulWidget {
  const _SharedFilesSheet();

  @override
  State<_SharedFilesSheet> createState() => _SharedFilesSheetState();
}

class _SharedFilesSheetState extends State<_SharedFilesSheet> {
  List<Map<String, dynamic>>? _items;
  String? _error;
  String? _deletingID;
  String? _downloadingID;
  double? _downloadPct; // download fraction for the active row (null = indeterminate)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final raw = await cloudService.listMyShares();
      if (!mounted) return;
      setState(() {
        _items = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _items = _items ?? [];
        _error = cleanBridgeError(e);
      });
    }
  }

  Future<void> _delete(Map<String, dynamic> item) async {
    final id = (item['id'] as String?) ?? '';
    final file = (item['file_name'] as String?) ?? '';
    final recipient = (item['recipient'] as String?) ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete share?'),
        content: Text('$recipient will no longer be able to download $file.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deletingID = id);
    try {
      await cloudService.cancelCloudShare(id);
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = cleanBridgeError(e));
    } finally {
      if (mounted) setState(() => _deletingID = null);
    }
  }

  // _download fetches a share's RAW encrypted .icfx (sender only — no decrypt)
  // and saves it to a user-chosen location. The file stays sealed; only the
  // recipient's key can open it. Mirrors the notification receive save flow.
  Future<void> _download(Map<String, dynamic> item, {bool force = false}) async {
    final id = (item['id'] as String?) ?? '';
    final fileName = (item['file_name'] as String?) ?? 'file.icfx';

    // Desktop picks the destination up front (XDG portal on Linux); mobile
    // leaves it empty so the SAF save dialog is the chooser.
    var destDir = '';
    final isMobile = Platform.isAndroid || Platform.isIOS;
    if (!isMobile) {
      try {
        final picked = await fileChooserService.pickDirectory('Save Encrypted File To…');
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
      _downloadingID = id;
      _downloadPct = null;
      _error = null;
    });
    try {
      var raw = '';
      await for (final p in cloudService.downloadRawShareStream(id, destDir, force)) {
        if (!mounted) return;
        if (p.phase == 'done') raw = p.result;
        setState(() => _downloadPct = p.pct);
      }
      if (!mounted) return;

      final result = await fileChooserService.handleWriteResult(raw, fileName);
      if (result.exists) {
        if (!mounted) return;
        setState(() => _downloadingID = null);
        final confirmed = await showOverwriteConfirmDialog(context, result.savedPath!);
        if (!confirmed || !mounted) return;
        await _download(item, force: true);
        return;
      }
      if (result.cancelled || !mounted) return;
      if (result.error != null) {
        setState(() => _error = result.error);
        return;
      }
      if (!mounted) return;
      showSuccessDialog(
        context,
        'Downloaded $fileName\n\nStill encrypted — only the recipient can open it.',
        result,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = cleanBridgeError(e));
    } finally {
      if (mounted) setState(() => _downloadingID = null);
    }
  }

  // _rowActions renders the per-row trailing controls: a raw-download button
  // and a delete button. A busy row shows a spinner in place of that action;
  // both actions are disabled while either is running (a small list, one at a time).
  Widget _rowActions(Map<String, dynamic> it, String id) {
    final busy = _deletingID != null || _downloadingID != null;
    final download = _downloadingID == id
        ? SizedBox(width: 20, height: 20, child: animatedProgressIndicator(_downloadPct))
        : IconButton(
            icon: const Icon(Icons.download_outlined, size: 20),
            tooltip: 'Download encrypted .icfx',
            onPressed: busy ? null : () => _download(it),
          );
    final delete = _deletingID == id
        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
        : IconButton(
            icon: const Icon(Icons.delete_outline, size: 20),
            tooltip: 'Delete share',
            onPressed: busy ? null : () => _delete(it),
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [download, delete],
    );
  }

  String _subtitle(Map<String, dynamic> it) {
    final parts = <String>[
      'to ${it['recipient']}',
      icShareHumanSize((it['file_size'] as num?)?.toInt() ?? 0),
    ];
    final status = (it['status'] as String?) ?? '';
    final singleUse = it['single_use'] == true;
    if (status == 'downloaded') {
      parts.add(singleUse ? 'single-use · downloaded' : 'downloaded');
      return parts.join(' · ');
    }
    parts.add('⬇${(it['download_count'] as num?)?.toInt() ?? 0}');
    if (singleUse) parts.add('single-use');
    parts.add(icShareExpiryLabel((it['ttl_expires_at'] as String?) ?? ''));
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Shared Files', style: theme.textTheme.titleMedium),
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
                    'No shared files.',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _items!.length,
                    itemBuilder: (ctx, i) {
                      final it = _items![i];
                      final id = (it['id'] as String?) ?? '';
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.insert_drive_file_outlined),
                        title: Text((it['file_name'] as String?) ?? ''),
                        subtitle: Text(_subtitle(it)),
                        trailing: _rowActions(it, id),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
