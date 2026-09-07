import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'package:webauthn/webauthn.dart';

import '../../bridge/bridge.gen.dart';
import '../../bridge/filechooser.dart';
import '../dialogs.dart' show showNewPassphraseDialog, showTextPromptDialog;
import '../hw_flow.dart' show ensureHWForNewIdentity, hwRequiredIdentityFrom, prepareHWForIdentity;
import '../plan_table.dart';
import '../webauthn_support.dart'
    show isMobileWebAuthnPlatform, mobileWebAuthnGetAssertion, platformWebAuthnSupported;
import '../sync_choice_screen.dart';
import 'wizard_scaffold.dart';

/// Which door the user chose on the welcome screen.
enum _Door { cloud, local, device }

/// Concrete wizard steps. `done` is shared across doors (its copy varies).
enum _Step { welcome, sync, identity, plans, account, verifyCode, login, twoFactor, done }

/// WelcomeWizard is the first-launch onboarding flow. It self-contains the three
/// doors (cloud / local / additional-device), calling the Flugo bridge for
/// identity creation and cloud account/session. On completion it marks the
/// welcome flag and calls onDone so the app routes to home.
///
/// Settings → Cloud can also relaunch it for a late cloud setup:
/// [cloudSetupOnly] starts directly in the cloud door at the sync step, and
/// [skipIdentity] omits the create-identity step when this device already has
/// identities.
class WelcomeWizard extends StatefulWidget {
  const WelcomeWizard({
    super.key,
    required this.onDone,
    this.cloudSetupOnly = false,
    this.skipIdentity = false,
  });

  final Future<void> Function() onDone;
  final bool cloudSetupOnly;
  final bool skipIdentity;

  @override
  State<WelcomeWizard> createState() => _WelcomeWizardState();
}

class _WelcomeWizardState extends State<WelcomeWizard> {
  _Door _door = _Door.cloud;
  _Step _step = _Step.welcome;

  // Identity fields.
  final _nameCtrl = TextEditingController();
  final _nickCtrl = TextEditingController();
  final _idEmailCtrl = TextEditingController();
  bool _useHWKey = false;
  // Opt-in cloud directory listing (cloud door only; publish is never default).
  bool _publishIdentity = false;

  // Cloud-account fields.
  final _cloudEmailCtrl = TextEditingController();
  final _cloudPwCtrl = TextEditingController();
  final _cloudPwConfirmCtrl = TextEditingController();

  // Additional-device login + 2FA fields.
  final _loginEmailCtrl = TextEditingController();
  final _loginPwCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _signupCodeCtrl = TextEditingController(); // 6-digit signup code
  // Advanced: custom cloud server URL, shared by the signup and login steps.
  final _serverCtrl = TextEditingController();

  // First-run sync-choice seed — opt-out, defaulted on (matches `icc cloud
  // enable|disable`). The live checkbox state is owned by SyncChoiceScreen; these
  // are just the initial values it's seeded with in the wizard.
  final bool _syncContacts = true;
  final bool _syncSettings = true;
  final bool _syncIdentities = true;

  // Second-factor challenge carried between login and twoFactor.
  String _tempToken = '';
  String _factor = '';
  String _webauthnOptions = ''; // assertion options for the webauthn factor
  bool _webAuthnSupported = false;

  bool _keychainAvailable = false;
  bool _busy = false;
  String? _error;
  bool _acceptedTerms = false; // gates the "Create account" button
  String _accountEmail = '';

  // Plans step (cloud door): the server's public catalog + the user's pick.
  // Everyone signs up Free; a paid pick auto-starts checkout after the
  // account is verified.
  List<Map<String, dynamic>> _planCatalog = const [];
  bool _planCatalogRequested = false;
  bool _planCatalogLoading = false;
  String? _planCatalogError;
  String _selectedTier = 'free';
  String _checkoutURL = '';
  String? _checkoutNote;

  @override
  void initState() {
    super.initState();
    if (widget.cloudSetupOnly) {
      _door = _Door.cloud;
      _step = _Step.sync;
    }
    unawaited(_loadKeychainAvailability());
    unawaited(_loadWebAuthnSupport());
    unawaited(_loadServerURL());
  }

  // Prefill the Advanced server field with the configured cloud URL (empty =
  // the default server).
  Future<void> _loadServerURL() async {
    try {
      final raw = jsonDecode(await icfxService.getSettings()) as Map<String, dynamic>;
      final url = (raw['cloud_base_url'] as String?) ?? '';
      if (mounted && url.isNotEmpty) _serverCtrl.text = url;
    } on FlugoException {
      // Non-fatal: the field just starts empty (default server).
    }
  }

  /// The step after the sync choices: identity creation, unless this launch
  /// skips it (Settings relaunch on a device that already has identities —
  /// then straight to the plans table).
  _Step get _afterSync =>
      widget.skipIdentity ? _Step.plans : _Step.identity;

  /// The step the plans table goes back to (mirrors [_afterSync]).
  _Step get _plansBack =>
      widget.skipIdentity ? _Step.sync : _Step.identity;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _nickCtrl.dispose();
    _idEmailCtrl.dispose();
    _cloudEmailCtrl.dispose();
    _cloudPwCtrl.dispose();
    _cloudPwConfirmCtrl.dispose();
    _loginEmailCtrl.dispose();
    _loginPwCtrl.dispose();
    _codeCtrl.dispose();
    _signupCodeCtrl.dispose();
    _serverCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadKeychainAvailability() async {
    try {
      final ok = await icfxService.keychainAvailable();
      if (mounted) setState(() => _keychainAvailable = ok);
    } on FlugoException {
      // Non-fatal: treat as file-backed (will prompt for a passphrase).
    }
  }

  Future<void> _loadWebAuthnSupport() async {
    try {
      final ok = await platformWebAuthnSupported();
      if (mounted) setState(() => _webAuthnSupported = ok);
    } on FlugoException {
      // Non-fatal: leave unsupported (mobile-style note shown).
    }
  }

  void _go(_Step s) => setState(() {
        _step = s;
        _error = null;
      });

  // Runs an async action with the busy spinner + inline error handling. Returns
  // true on success.
  Future<bool> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = _clean(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _clean(Object e) {
    final s = e is FlugoException ? e.message : e.toString();
    return s.replaceFirst('Exception: ', '');
  }

  // --- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case _Step.welcome:
        return _welcome();
      case _Step.sync:
        return _sync();
      case _Step.identity:
        return _identity();
      case _Step.plans:
        return _plans();
      case _Step.account:
        return _account();
      case _Step.verifyCode:
        return _verifyCode();
      case _Step.login:
        return _login();
      case _Step.twoFactor:
        return _twoFactor();
      case _Step.done:
        return _done();
    }
  }

  // Dot index/count per door+step. welcome/done-on-device handled inline.
  ({int index, int count}) _dots() {
    switch (_door) {
      case _Door.cloud:
        final order = widget.skipIdentity
            ? [_Step.sync, _Step.plans, _Step.account, _Step.verifyCode, _Step.done]
            : [_Step.sync, _Step.identity, _Step.plans, _Step.account, _Step.verifyCode, _Step.done];
        return (index: order.indexOf(_step), count: order.length);
      case _Door.local:
        const order = [_Step.identity, _Step.done];
        return (index: order.indexOf(_step), count: order.length);
      case _Door.device:
        final order = _factor.isEmpty
            ? [_Step.login, _Step.sync, _Step.done]
            : [_Step.login, _Step.twoFactor, _Step.sync, _Step.done];
        return (index: order.indexOf(_step), count: order.length);
    }
  }

  Widget _welcome() {
    return WizardScaffold(
      title: 'Instacrypt',
      subtitle: 'Encrypt files for anyone — no passwords to share.',
      error: _error,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _doorButton(
            label: 'Set up with cloud',
            hint: 'Recommended — sync across devices',
            filled: true,
            onTap: () {
              _door = _Door.cloud;
              _go(_Step.sync);
            },
          ),
          const SizedBox(height: 12),
          _doorButton(
            label: 'I have an account',
            hint: 'Add this device to your account',
            onTap: () {
              _door = _Door.device;
              _go(_Step.login);
            },
          ),
          const SizedBox(height: 12),
          _doorButton(
            label: 'Local only (no account)',
            hint: 'Everything stays on this device',
            onTap: () {
              _door = _Door.local;
              _go(_Step.identity);
            },
          ),
        ],
      ),
    );
  }

  Widget _doorButton({
    required String label,
    required String hint,
    required VoidCallback onTap,
    bool filled = false,
  }) {
    final theme = Theme.of(context);
    // The theme text styles carry the light onSurface color; on the filled
    // (primary-background) button the readable foreground is onPrimary.
    final fg = filled ? theme.colorScheme.onPrimary : null;
    final child = Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(label, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: fg)),
        const SizedBox(height: 2),
        Text(hint, style: theme.textTheme.bodySmall?.copyWith(color: fg)),
      ],
    );
    final padding = const EdgeInsets.symmetric(vertical: 14, horizontal: 16);
    if (filled) {
      return FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(padding: padding, minimumSize: const Size.fromHeight(64)),
        child: child,
      );
    }
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(padding: padding, minimumSize: const Size.fromHeight(64)),
      child: child,
    );
  }

  Widget _sync() {
    final d = _dots();
    final device = _door == _Door.device;
    // Reuses the shared SyncChoiceScreen — the same widget the Settings re-login
    // flow presents (pre-filled), so the two stay in lockstep.
    return SyncChoiceScreen(
      initialContacts: _syncContacts,
      initialSettings: _syncSettings,
      initialIdentities: _syncIdentities,
      subtitle: device
          ? 'Choose what syncs to this device. Stored encrypted — the server only ever sees ciphertext.'
          : 'Stored encrypted — the server only ever sees ciphertext.',
      stepIndex: d.index,
      stepCount: d.count,
      error: _error,
      busy: _busy,
      // Device door arrives here already signed in — no back.
      onBack: widget.cloudSetupOnly || device ? null : () => _go(_Step.welcome),
      // Settings → "Set Up With Cloud" starts on this step with no Back; let the
      // user cancel out (onDone pops back to Settings; cloud stays off).
      onCancel: widget.cloudSetupOnly ? () => unawaited(widget.onDone()) : null,
      primaryLabel: 'Continue',
      onConfirm: (contacts, settings, identities) async {
        final ok = await _run(() async {
          // Enables cloud (cfg.CloudEnabled) + the per-resource flags.
          await cloudService.setSyncTiers(contacts, settings, identities);
          if (device) await _firstDeviceSync();
        });
        if (!ok) return;
        _go(device ? _Step.done : _afterSync);
      },
    );
  }

  Widget _identity() {
    final d = _dots();
    return WizardScaffold(
      title: 'Create your identity',
      subtitle: 'This generates your lock (public) and key (private).',
      stepIndex: d.index,
      stepCount: d.count,
      error: _error,
      busy: _busy,
      onBack: () => _go(_door == _Door.cloud ? _Step.sync : _Step.welcome),
      primaryLabel: 'Continue',
      onPrimary: () async {
        if (await _createIdentity()) {
          _go(_door == _Door.cloud ? _Step.plans : _Step.done);
        }
      },
      body: Column(
        children: [
          _field(_nameCtrl, 'Name'),
          const SizedBox(height: 12),
          _field(_nickCtrl, 'Nickname (optional)'),
          const SizedBox(height: 12),
          _field(_idEmailCtrl, 'Email (optional)'),
          const SizedBox(height: 8),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _useHWKey,
            onChanged: (v) => setState(() => _useHWKey = v ?? false),
            title: const Text('Protect with a hardware key'),
          ),
          if (_door == _Door.cloud)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _publishIdentity,
              onChanged: (v) => setState(() => _publishIdentity = v ?? false),
              title: const Text('List in the cloud directory'),
              subtitle: const Text('Contacts can find you by name or email (requires the email above). You can publish or unpublish anytime in Settings.'),
            ),
        ],
      ),
    );
  }

  Future<bool> _createIdentity() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter a name.');
      return false;
    }
    if (_publishIdentity && _door == _Door.cloud && _idEmailCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Publishing to the directory requires an email on the identity.');
      return false;
    }
    if (_useHWKey && !await ensureHWForNewIdentity(context, name)) return false;
    return _run(() async {
      if (!_keychainAvailable) {
        if (!mounted) return;
        final ppBytes = await showNewPassphraseDialog(context);
        if (ppBytes == null) throw Exception('A passphrase is required to protect your key.');
        try {
          await icfxService.unlock(ppBytes);
        } finally {
          ppBytes.fillRange(0, ppBytes.length, 0);
        }
      }
      await icfxService.createKeys(
        name, _nickCtrl.text.trim(), _idEmailCtrl.text.trim(), '', '', _useHWKey);
    });
  }

  Future<void> _loadPlanCatalog() async {
    setState(() {
      _planCatalogLoading = true;
      _planCatalogError = null;
    });
    try {
      final raw = await cloudService.planCatalog();
      if (!mounted) return;
      setState(() {
        _planCatalog =
            (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
        _planCatalogLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        // Never blocks signup: Continue proceeds on the Free tier and the
        // Plan dialog shows the table once the server is reachable.
        _planCatalogError = 'Couldn\'t load plans from the server — continuing on the Free plan.';
        _planCatalogLoading = false;
      });
    }
  }

  Widget _plans() {
    if (!_planCatalogRequested) {
      _planCatalogRequested = true;
      unawaited(_loadPlanCatalog());
    }
    final d = _dots();
    final theme = Theme.of(context);
    return WizardScaffold(
      title: 'Choose a plan',
      subtitle: 'Every account starts on Free — paid plans are activated right after signup. You can change plans anytime in Settings → Plan.',
      stepIndex: d.index,
      stepCount: d.count,
      error: _error,
      busy: _busy,
      onBack: () => _go(_plansBack),
      primaryLabel: 'Continue',
      onPrimary: () async => _go(_Step.account),
      body: Column(
        children: [
          if (_planCatalogLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_planCatalogError != null)
            Text(
              _planCatalogError!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          if (!_planCatalogLoading && _planCatalog.isNotEmpty)
            PlanTable(
              catalog: _planCatalog,
              mode: PlanTableMode.select,
              highlightTier: _selectedTier,
              onSelect: (tier, _) {
                setState(() => _selectedTier = tier);
                _go(_Step.account);
              },
            ),
        ],
      ),
    );
  }

  Widget _account() {
    final d = _dots();
    return WizardScaffold(
      title: 'Create your cloud account',
      subtitle: 'We store only ciphertext and your lock — never your key.',
      stepIndex: d.index,
      stepCount: d.count,
      error: _error,
      busy: _busy,
      onBack: () => _go(_Step.plans),
      primaryLabel: 'Create',
      onPrimary: _createAccount,
      primaryEnabled: _acceptedTerms,
      body: Column(
        children: [
          _field(_cloudEmailCtrl, 'Email', keyboard: TextInputType.emailAddress),
          const SizedBox(height: 12),
          _field(_cloudPwCtrl, 'Password (min 12 chars)', obscure: true),
          const SizedBox(height: 12),
          _field(_cloudPwConfirmCtrl, 'Confirm password', obscure: true),
          const SizedBox(height: 8),
          _termsConsent(),
          const SizedBox(height: 12),
          _advancedSection(),
        ],
      ),
    );
  }

  // Required Terms + Privacy acceptance: a modern toggle beside the consent
  // line, whose "Terms of Service" and "Privacy Policy" open the live pages.
  // The Create button stays disabled until the toggle is on.
  Widget _termsConsent() {
    final theme = Theme.of(context);
    final linkStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('I agree to the ', style: theme.textTheme.bodyMedium),
              InkWell(
                onTap: () => fileChooserService.openUrl('https://instacrypt.io/terms'),
                child: Text('Terms of Service', style: linkStyle),
              ),
              Text(' and ', style: theme.textTheme.bodyMedium),
              InkWell(
                onTap: () => fileChooserService.openUrl('https://instacrypt.io/privacy'),
                child: Text('Privacy Policy', style: linkStyle),
              ),
            ],
          ),
        ),
        Switch(
          value: _acceptedTerms,
          onChanged: (v) => setState(() => _acceptedTerms = v),
        ),
      ],
    );
  }

  // Collapsed Advanced section for the signup/login steps: a custom cloud
  // server URL, applied through cloudService.setServerURL before the auth
  // call (the only path that rebuilds the cached cloud client).
  Widget _advancedSection() {
    final theme = Theme.of(context);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      shape: const Border(),
      collapsedShape: const Border(),
      title: Text(
        'Advanced',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      children: [
        _field(_serverCtrl, 'Cloud server URL', keyboard: TextInputType.url),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Leave empty for the default server (cloud.instacrypt.io).',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  // _applyServerURL points the backend's cloud client at the Advanced
  // section's server (or the default when empty) — must run before
  // signUp/logIn, which lazily build the client.
  Future<void> _applyServerURL() {
    return cloudService.setServerURL(_serverCtrl.text.trim());
  }

  Future<void> _createAccount() async {
    final email = _cloudEmailCtrl.text.trim();
    final pw = _cloudPwCtrl.text;
    if (email.isEmpty) {
      setState(() => _error = 'Please enter an email.');
      return;
    }
    if (pw.length < 12) {
      setState(() => _error = 'Password must be at least 12 characters.');
      return;
    }
    if (pw != _cloudPwConfirmCtrl.text) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }
    final ok = await _run(() async {
      await _applyServerURL();
      await _sendCloudPassword(pw);
      // Pending-signup model: this only emails a 6-digit code. No account
      // exists until the code is confirmed on the next step.
      await cloudService.signUp(email, _acceptedTerms);
      _accountEmail = email;
    });
    if (!ok) return;
    _signupCodeCtrl.clear();
    _go(_Step.verifyCode);
  }

  Widget _verifyCode() {
    final d = _dots();
    return WizardScaffold(
      title: 'Check your email',
      subtitle: 'We sent a 6-digit code to $_accountEmail. Signup completes only after you enter it.',
      stepIndex: d.index,
      stepCount: d.count,
      error: _error,
      busy: _busy,
      onBack: () => _go(_Step.account),
      primaryLabel: 'Verify',
      onPrimary: _confirmSignupCode,
      body: Column(
        children: [
          _field(_signupCodeCtrl, '6-digit code', keyboard: TextInputType.number),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _busy ? null : _resendSignupCode,
            child: const Text('Resend code'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmSignupCode() async {
    final code = _signupCodeCtrl.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6-digit code from the email.');
      return;
    }
    final ok = await _run(() async {
      // Creates the account (born verified) and lands signed-in — the
      // encryption key from signup is already held by the backend client.
      await cloudService.confirmSignUp(code);
      // Best-effort first sync via the shared engine (fresh account → pushes;
      // existing data → pulls). The Cloud tab can re-run it anytime.
      try {
        await cloudService.sync();
      } on FlugoException {
        // Non-fatal — account is created; leave a note but continue.
      }
    });
    if (!ok) return;

    // Opt-in directory publish, now that the session is live. Non-fatal:
    // the account and identity are fine either way.
    String? publishError;
    if (_publishIdentity && _door == _Door.cloud) {
      try {
        await cloudService.publishIdentity(_nameCtrl.text.trim());
      } catch (e) {
        publishError =
            'Signed up, but publishing to the directory failed: ${_clean(e)} '
            'You can publish later from Settings → Keys.';
      }
    }

    // Paid plan picked on the Plans step: start its checkout now that the
    // account is verified. Non-fatal — skipping or failing payment leaves a
    // working Free account, and Settings → Plan can retry anytime.
    String? checkoutError;
    if (_selectedTier != 'free') {
      final label = _selectedTier[0].toUpperCase() + _selectedTier.substring(1);
      try {
        final url = await cloudService.upgradePlan(_selectedTier);
        final opened = await openCheckoutUrl(url);
        _checkoutURL = url;
        _checkoutNote = opened
            ? 'Complete the payment in your browser to activate $label.'
            : 'Couldn\'t open your browser — use Copy Link below to finish activating $label.';
      } catch (e) {
        if (e.toString().contains('already_subscribed')) {
          // The server found (and adopted) a live subscription — success.
          _checkoutNote = '$label is already active on this account.';
        } else {
          checkoutError =
              'Signed up, but starting the $label checkout failed: ${_clean(e)} '
              'You can upgrade anytime in Settings → Plan.';
        }
      }
    }

    _go(_Step.done);
    final notes = [publishError, checkoutError].whereType<String>();
    if (notes.isNotEmpty && mounted) {
      setState(() => _error = notes.join('\n'));
    }
  }

  Future<void> _resendSignupCode() async {
    final ok = await _run(() => cloudService.resendSignupCode());
    if (ok && mounted) setState(() => _error = null);
  }

  // _sendCloudPassword ships the password over the raw-bytes secure channel and
  // zeroes the transient buffer immediately after.
  Future<void> _sendCloudPassword(String pw) async {
    final bytes = Uint8List.fromList(utf8.encode(pw));
    try {
      await cloudService.setPassword(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Widget _login() {
    final d = _dots();
    return WizardScaffold(
      title: 'Add this device',
      subtitle: 'Sign in to your Instacrypt account.',
      stepIndex: d.index,
      stepCount: d.count,
      error: _error,
      busy: _busy,
      onBack: () => _go(_Step.welcome),
      primaryLabel: 'Log in',
      onPrimary: _doLogin,
      body: Column(
        children: [
          _field(_loginEmailCtrl, 'Email', keyboard: TextInputType.emailAddress),
          const SizedBox(height: 12),
          _field(_loginPwCtrl, 'Password', obscure: true),
          const SizedBox(height: 12),
          _advancedSection(),
        ],
      ),
    );
  }

  Future<void> _doLogin() async {
    final email = _loginEmailCtrl.text.trim();
    if (email.isEmpty || _loginPwCtrl.text.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }
    final ok = await _run(() async {
      await _applyServerURL();
      await _sendCloudPassword(_loginPwCtrl.text);
      final challenge = await cloudService.logIn(email);
      _accountEmail = email;
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
    _go(_factor.isEmpty ? _Step.sync : _Step.twoFactor);
  }

  Widget _twoFactor() {
    final d = _dots();
    final webauthn = _factor == 'webauthn';
    return WizardScaffold(
      title: webauthn ? 'Security key' : 'Two-factor code',
      subtitle: switch (_factor) {
        'email' => 'Enter the code we emailed to $_accountEmail.',
        'webauthn' => _webAuthnSupported
            ? 'This account is protected by a hardware security key.'
            : 'Hardware-key sign-in isn\'t supported on this device — use the desktop app or CLI.',
        _ => 'Enter the code from your authenticator (or a recovery code).',
      },
      stepIndex: d.index,
      stepCount: d.count,
      error: _error,
      busy: _busy,
      onBack: () => _go(_Step.login),
      primaryLabel: webauthn ? 'Use Security Key' : 'Verify',
      primaryEnabled: _factor == 'totp' || _factor == 'email' || (webauthn && _webAuthnSupported),
      onPrimary: () async {
        if (webauthn) {
          await _webAuthnLogin();
          return;
        }
        final ok = await _run(() async {
          if (_factor == 'email') {
            await cloudService.logInEmail(_tempToken, _codeCtrl.text.trim());
            return;
          }
          await cloudService.logInTOTP(_tempToken, _codeCtrl.text.trim());
        });
        if (ok) _go(_Step.sync);
      },
      body: Column(
        children: [
          if (!webauthn) _field(_codeCtrl, 'Code'),
        ],
      ),
    );
  }

  // _webAuthnLogin drives the security-key assertion: PIN prompt → touch
  // (the wizard's busy spinner covers the wait) → session established.
  Future<void> _webAuthnLogin() async {
    if (isMobileWebAuthnPlatform) {
      // Play-Services-free CTAP2 ceremony over USB/NFC (PIN + present-key prompt
      // inside the helper). The login POST goes through `_run`.
      String? resp;
      try {
        resp = await mobileWebAuthnGetAssertion(context, _webauthnOptions);
      } on WebauthnException catch (e) {
        if (e.code != 'cancelled' && mounted) {
          setState(() => _error = 'Security key sign-in failed: ${e.message}');
        }
        return;
      }
      if (resp == null || !mounted) return; // cancelled
      final assertion = resp;
      final ok = await _run(() => cloudService.logInWebAuthnNative(_tempToken, assertion));
      if (ok) _go(_Step.sync);
      return;
    }
    final pin = await showTextPromptDialog(
      context,
      title: 'Security Key PIN',
      label: 'PIN',
      hint: 'Plug the key in, enter its PIN, then touch it when it blinks',
      obscure: true,
    );
    if (pin == null || pin.isEmpty || !mounted) return;
    final ok = await _run(() async {
      final bytes = Uint8List.fromList(utf8.encode(pin));
      try {
        await cloudService.setSecurityKeyPIN(bytes);
      } finally {
        bytes.fillRange(0, bytes.length, 0);
      }
      await cloudService.logInWebAuthn(_tempToken, _webauthnOptions);
    });
    if (ok) _go(_Step.sync);
  }

  // First sync for a newly added device: pulls identities/contacts/settings
  // per the sync choices. If a roamed-down identity is hardware-key-backed,
  // the contacts/settings leg reports the "hardware key required" marker —
  // run the tap flow and retry once. Non-HW outcome errors don't block the
  // wizard: cloud is enabled now, so auto-sync (and Sync Now) catch up.
  Future<void> _firstDeviceSync({bool retried = false}) async {
    final raw = await cloudService.sync();
    final outcomes = (jsonDecode(raw) as List<dynamic>).cast<Map<String, dynamic>>();
    for (final o in outcomes) {
      final hwIdentity = hwRequiredIdentityFrom((o['error'] as String?) ?? '');
      if (hwIdentity == null || retried) continue;
      if (!mounted) return;
      final ready = await prepareHWForIdentity(context, hwIdentity);
      if (!ready) return; // tap cancelled — Sync Now in Settings catches up
      return _firstDeviceSync(retried: true);
    }
  }

  Widget _done() {
    final d = _dots();
    final theme = Theme.of(context);
    String subtitle;
    switch (_door) {
      case _Door.cloud:
        subtitle = 'Your email is verified and you\'re signed in on this device.';
      case _Door.device:
        subtitle = 'You\'re signed in and your first sync has run.';
      case _Door.local:
        subtitle = 'Your identity is ready on this device.';
    }
    return WizardScaffold(
      title: 'All set!',
      subtitle: subtitle,
      stepIndex: d.index,
      stepCount: d.count,
      error: _error,
      busy: _busy,
      primaryLabel: 'Go to Instacrypt',
      onPrimary: () async {
        final ok = await _run(() => icfxService.markWelcomeCompleted());
        if (ok && mounted) await widget.onDone();
      },
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_door == _Door.device)
            Text(
              'Keys not in cloud sync? Import a backup anytime in Settings → Advanced.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          if (_checkoutNote != null) ...[
            Text(
              _checkoutNote!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
            ),
            if (_checkoutURL.isNotEmpty)
              TextButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('Copy Link'),
                onPressed: () async {
                  final item = DataWriterItem();
                  item.add(Formats.plainText(_checkoutURL));
                  await SystemClipboard.instance?.write([item]);
                  if (!mounted) return;
                  setState(() => _checkoutNote = 'Payment link copied — open it in any browser.');
                },
              ),
          ],
        ],
      ),
    );
  }

  // --- small widgets ---------------------------------------------------------

  Widget _field(
    TextEditingController c,
    String label, {
    bool obscure = false,
    TextInputType? keyboard,
  }) {
    return TextField(
      controller: c,
      obscureText: obscure,
      keyboardType: keyboard,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    );
  }
}

