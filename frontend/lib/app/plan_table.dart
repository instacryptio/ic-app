import 'package:flutter/material.dart';

import '../bridge/filechooser.dart';

/// Opens a server-provided billing/checkout URL — but ONLY if it is https, so a
/// compromised billing server can't hand a file:// or custom scheme to the OS
/// launcher. (openUrl itself legitimately opens file:// for local files, so the
/// scheme guard belongs here at the payment call sites, not in openUrl.) Returns
/// false without launching for any non-https or unparseable URL.
Future<bool> openCheckoutUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.scheme.toLowerCase() != 'https') return false;
  return fileChooserService.openUrl(url);
}

/// How a [PlanTable]'s footer row behaves.
///
/// [select] — a "Select" button under every tier (welcome wizard: pick a
/// plan before signup). [manage] — a "Current" chip under the active tier
/// and Upgrade/Downgrade buttons under the others (Settings → Plan).
enum PlanTableMode { select, manage }

/// PlanTable renders the server's public plan catalog as a comparison grid:
/// tiers as columns, features as rows. Shared by the Settings Plan dialog
/// and the welcome wizard so pricing is presented identically everywhere.
/// The catalog rows come from `CloudService.PlanCatalog` verbatim — nothing
/// here is hardcoded; tiers render exactly as the server defines them.
class PlanTable extends StatelessWidget {
  const PlanTable({
    super.key,
    required this.catalog,
    required this.mode,
    this.highlightTier,
    this.busy = false,
    this.onSelect,
  });

  /// Decoded /v1/plans entries, in the server's upgrade order.
  final List<Map<String, dynamic>> catalog;

  final PlanTableMode mode;

  /// Column to tint: the current tier (manage) or the picked one (select).
  final String? highlightTier;

  /// Disables the footer buttons while an action is in flight.
  final bool busy;

  /// Called with the tapped tier; isUpgrade compares catalog positions
  /// against [highlightTier] (always true when there is no highlight).
  final void Function(String tier, bool isUpgrade)? onSelect;

  int _indexOf(String? tier) =>
      catalog.indexWhere((e) => e['tier'] == tier);

  String _label(String tier) =>
      tier.isEmpty ? tier : tier[0].toUpperCase() + tier.substring(1);

  String _price(Map<String, dynamic> e) {
    final cents = (e['price_monthly_cents'] as num?)?.toInt() ?? 0;
    if (cents == 0) return '\$0';
    if (cents % 100 == 0) return '\$${cents ~/ 100}/mo';
    return '\$${(cents / 100).toStringAsFixed(2)}/mo';
  }

  String _contacts(Map<String, dynamic> e) {
    final n = (e['max_contacts'] as num?)?.toInt() ?? 0;
    if (n >= 1000) {
      final s = n.toString();
      return '${s.substring(0, s.length - 3)},${s.substring(s.length - 3)}';
    }
    return '$n';
  }

  String _maxFile(Map<String, dynamic> e) {
    final b = (e['max_file_size_bytes'] as num?)?.toInt() ?? 0;
    if (b <= 0) return '–';
    if (b % (1 << 30) == 0) return '${b ~/ (1 << 30)} GiB';
    return '${(b / (1 << 30)).toStringAsFixed(1)} GiB';
  }

  String _shares(Map<String, dynamic> e) {
    final n = (e['max_active_shares'] as num?)?.toInt() ?? 0;
    return n <= 0 ? '–' : '$n';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highlightIdx = _indexOf(highlightTier);
    final tint = theme.colorScheme.primaryContainer.withValues(alpha: 0.35);
    final cellStyle = theme.textTheme.bodySmall;
    final headStyle =
        theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold);

    Widget cell(Widget child, int col, {EdgeInsets? padding}) {
      return Container(
        color: col == highlightIdx + 1 && highlightIdx >= 0 ? tint : null,
        padding:
            padding ?? const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        alignment: col == 0 ? Alignment.centerLeft : Alignment.center,
        child: child,
      );
    }

    Widget textCell(String text, int col, {bool head = false}) => cell(
          Text(text,
              style: head ? headStyle : cellStyle,
              textAlign: col == 0 ? TextAlign.left : TextAlign.center),
          col,
        );

    TableRow featureRow(String label, String Function(Map<String, dynamic>) value) {
      return TableRow(children: [
        textCell(label, 0),
        for (var i = 0; i < catalog.length; i++)
          textCell(value(catalog[i]), i + 1),
      ]);
    }

    Widget footerCell(int i) {
      final tier = catalog[i]['tier'] as String;
      final isUpgrade = highlightIdx < 0 || i > highlightIdx;

      switch (mode) {
        case PlanTableMode.select:
          return cell(
            FittedBox(
              fit: BoxFit.scaleDown,
              child: TextButton(
                onPressed: busy ? null : () => onSelect?.call(tier, isUpgrade),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                child: const Text('Select'),
              ),
            ),
            i + 1,
            padding: const EdgeInsets.symmetric(vertical: 2),
          );
        case PlanTableMode.manage:
          if (i == highlightIdx) {
            return cell(
              Text('Current',
                  style: cellStyle?.copyWith(fontWeight: FontWeight.bold)),
              i + 1,
            );
          }
          // Free never gets a manage button — leaving a paid plan is the
          // Cancel flow, not a "downgrade to free" purchase.
          if ((catalog[i]['price_monthly_cents'] as num?) == 0) {
            return cell(const SizedBox.shrink(), i + 1);
          }
          return cell(
            FittedBox(
              fit: BoxFit.scaleDown,
              child: TextButton(
                onPressed: busy ? null : () => onSelect?.call(tier, isUpgrade),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                child: Text(isUpgrade ? 'Upgrade' : 'Downgrade'),
              ),
            ),
            i + 1,
            padding: const EdgeInsets.symmetric(vertical: 2),
          );
      }
    }

    // In manage mode an unknown tier (newer server than this app) shows no
    // footer at all — offering "Upgrade to Basic" there would be an
    // accidental downgrade. Callers render their own explanatory note.
    final showFooter = onSelect != null &&
        !(mode == PlanTableMode.manage && highlightIdx < 0);

    return Table(
      columnWidths: {
        0: const FlexColumnWidth(1.25),
        for (var i = 0; i < catalog.length; i++) i + 1: const FlexColumnWidth(1),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder(
        horizontalInside: BorderSide(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          width: 0.5,
        ),
      ),
      children: [
        TableRow(children: [
          textCell('', 0),
          for (var i = 0; i < catalog.length; i++)
            textCell(_label(catalog[i]['tier'] as String), i + 1, head: true),
        ]),
        featureRow('Price', _price),
        featureRow('Contacts', _contacts),
        featureRow('Backup', (e) => e['backup_allowed'] == true ? '✓' : '–'),
        featureRow('Shares', _shares),
        featureRow('Max file', _maxFile),
        if (showFooter)
          TableRow(children: [
            textCell('', 0),
            for (var i = 0; i < catalog.length; i++) footerCell(i),
          ]),
      ],
    );
  }
}
