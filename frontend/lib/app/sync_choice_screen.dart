import 'package:flutter/material.dart';

import 'onboarding/wizard_scaffold.dart';

/// A single sync-tier checkbox row. Shared by the onboarding wizard's sync step
/// and the Settings re-login sync-choice prompt so they stay in lockstep.
class SyncCheckRow extends StatelessWidget {
  const SyncCheckRow({
    super.key,
    required this.value,
    required this.label,
    required this.hint,
    this.onChanged,
  });

  final bool value;
  final String label;
  final String hint;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: value,
      onChanged: onChanged != null ? (v) => onChanged!(v ?? false) : null,
      title: Text(label),
      subtitle: Text(hint),
    );
  }
}

/// The "What should sync?" choice — three tiers, **pre-filled** from the initial
/// values and confirmed via [onConfirm]. Owns its own checkbox state (seeded once
/// from the initial args), so it's the single source of the sync-choice UI reused
/// by the onboarding wizard step AND the Settings login flow (where logging back
/// in re-presents it pre-filled with the user's last choices).
class SyncChoiceScreen extends StatefulWidget {
  const SyncChoiceScreen({
    super.key,
    required this.initialContacts,
    required this.initialSettings,
    required this.initialIdentities,
    required this.onConfirm,
    this.onBack,
    this.onCancel,
    this.subtitle = 'Stored encrypted — the server only ever sees ciphertext.',
    this.primaryLabel = 'Continue',
    this.busy = false,
    this.error,
    this.stepIndex,
    this.stepCount,
  });

  final bool initialContacts;
  final bool initialSettings;
  final bool initialIdentities;

  /// Called with the final tier choices when the user confirms.
  final Future<void> Function(bool contacts, bool settings, bool identities) onConfirm;

  final VoidCallback? onBack;
  final VoidCallback? onCancel;
  final String subtitle;
  final String primaryLabel;
  final bool busy;
  final String? error;
  final int? stepIndex;
  final int? stepCount;

  @override
  State<SyncChoiceScreen> createState() => _SyncChoiceScreenState();
}

class _SyncChoiceScreenState extends State<SyncChoiceScreen> {
  late bool _contacts = widget.initialContacts;
  late bool _settings = widget.initialSettings;
  late bool _identities = widget.initialIdentities;

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      title: 'What should sync?',
      subtitle: widget.subtitle,
      stepIndex: widget.stepIndex,
      stepCount: widget.stepCount,
      error: widget.error,
      busy: widget.busy,
      onBack: widget.onBack,
      onCancel: widget.onCancel,
      primaryLabel: widget.primaryLabel,
      onPrimary: () => widget.onConfirm(_contacts, _settings, _identities),
      body: Column(
        children: [
          SyncCheckRow(
            value: _contacts,
            label: 'Contacts & Groups',
            hint: 'Roam your contacts and groups across devices',
            onChanged: (v) => setState(() => _contacts = v),
          ),
          SyncCheckRow(
            value: _settings,
            label: 'Settings',
            hint: 'Roam preferences across devices',
            onChanged: (v) => setState(() => _settings = v),
          ),
          SyncCheckRow(
            value: _identities,
            label: 'Identities (Keys)',
            hint: 'Full multi-device key portability',
            onChanged: (v) => setState(() => _identities = v),
          ),
        ],
      ),
    );
  }
}
