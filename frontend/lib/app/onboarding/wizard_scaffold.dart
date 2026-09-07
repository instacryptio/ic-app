import 'package:flutter/material.dart';

/// WizardScaffold is the shared minimal-centered layout for every onboarding
/// step: an optional dot progress indicator, a centered title/subtitle, the
/// step body, an optional inline error, and a Back/primary-action footer.
///
/// It is deliberately plain so each step reads the same way. The window is
/// narrow (480x720 desktop / phone), so everything is a single centered column.
class WizardScaffold extends StatelessWidget {
  const WizardScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.body,
    this.stepIndex,
    this.stepCount,
    this.onBack,
    this.onCancel,
    this.primaryLabel,
    this.onPrimary,
    this.primaryEnabled = true,
    this.busy = false,
    this.error,
  });

  final String title;
  final String? subtitle;
  final Widget body;

  /// 0-based index within the current path's step list; null hides the dots.
  final int? stepIndex;
  final int? stepCount;

  final VoidCallback? onBack;
  /// Optional secondary action (e.g. dismissing a Settings-relaunched wizard).
  final VoidCallback? onCancel;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final bool primaryEnabled;
  final bool busy;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (stepIndex != null && stepCount != null) ...[
                    _WizardDots(current: stepIndex!, total: stepCount!),
                    const SizedBox(height: 24),
                  ],
                  Icon(Icons.lock_outline, size: 44, color: theme.colorScheme.primary),
                  const SizedBox(height: 12),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      subtitle!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  body,
                  if (error != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                    ),
                  ],
                  const SizedBox(height: 24),
                  _footer(context),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _footer(BuildContext context) {
    final hasBack = onBack != null;
    final hasCancel = onCancel != null;
    final hasPrimary = primaryLabel != null && onPrimary != null;
    if (!hasBack && !hasCancel && !hasPrimary) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        if (hasBack)
          TextButton(
            onPressed: busy ? null : onBack,
            child: const Text('Back'),
          ),
        if (hasCancel)
          TextButton(
            onPressed: busy ? null : onCancel,
            child: const Text('Cancel'),
          ),
        const Spacer(),
        if (hasPrimary)
          FilledButton(
            onPressed: (busy || !primaryEnabled) ? null : onPrimary,
            child: busy
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(primaryLabel!),
          ),
      ],
    );
  }
}

/// _WizardDots renders `total` dots with `current` filled.
class _WizardDots extends StatelessWidget {
  const _WizardDots({required this.current, required this.total});

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(total, (i) {
        final active = i == current;
        return Container(
          width: active ? 10 : 8,
          height: active ? 10 : 8,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurface.withValues(alpha: 0.25),
          ),
        );
      }),
    );
  }
}
