import 'dart:async';

import 'package:dropdown_search/dropdown_search.dart';
import 'package:flutter/material.dart';

import 'settings_shared.dart';

/// Contact Groups tab: create/edit/delete named groups of contacts, used as a
/// shortcut to encrypt/share to several people at once. Mirrors the Contacts
/// tab conventions (StatelessWidget shell + StatefulWidget dialogs whose
/// TextEditingControllers are owned and disposed by the dialog State).
class SettingsGroupsTab extends StatelessWidget {
  const SettingsGroupsTab({
    super.key,
    required this.groups,
    required this.contacts,
    required this.hasKeys,
    required this.isLoading,
    required this.onAddGroup,
    required this.onEditGroup,
    required this.onRemoveGroup,
    required this.onRefresh,
    required this.onError,
    required this.onStatus,
  });

  final List<Map<String, dynamic>> groups;

  /// All contacts — the pool the member picker chooses from (by alias).
  final List<Map<String, dynamic>> contacts;
  final bool hasKeys;
  final bool isLoading;
  final Future<void> Function(String name, List<String> memberAliases) onAddGroup;
  final Future<void> Function(String id, String name, List<String> memberAliases) onEditGroup;
  final Future<void> Function(String id) onRemoveGroup;
  final Future<void> Function() onRefresh;
  final void Function(String message) onError;
  final void Function(String message) onStatus;

  List<String> get _contactAliases =>
      contacts.map((c) => c['alias'] as String).toList();

  List<String> _memberAliases(Map<String, dynamic> group) {
    final members = (group['members'] as List?) ?? const [];
    return members.map((m) => (m as Map)['alias'] as String).toList();
  }

  void _showAddDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => _GroupDialog(
        title: 'New Group',
        submitLabel: 'Create',
        contactAliases: _contactAliases,
        onSubmit: (name, members) => onAddGroup(name, members),
        onError: onError,
        onRefresh: onRefresh,
      ),
    );
  }

  void _showEditDialog(BuildContext context, Map<String, dynamic> group) {
    showDialog<void>(
      context: context,
      builder: (_) => _GroupDialog(
        title: 'Edit Group',
        submitLabel: 'Save',
        initialName: group['name'] as String? ?? '',
        initialMembers: _memberAliases(group),
        contactAliases: _contactAliases,
        onSubmit: (name, members) =>
            onEditGroup(group['id'] as String, name, members),
        onError: onError,
        onRefresh: onRefresh,
      ),
    );
  }

  void _showRemoveDialog(BuildContext context, Map<String, dynamic> group) {
    final name = group['name'] as String? ?? '';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Group'),
        content: Text('Delete the group "$name"? Your contacts are not affected.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () async {
              Navigator.of(ctx).pop();
              try {
                await onRemoveGroup(group['id'] as String);
              } catch (e) {
                onError('Failed to delete group: $e');
              }
              await onRefresh();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (groups.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 32),
            child: Text(
              hasKeys
                  ? 'No groups yet. Create one to encrypt to several contacts at once.'
                  : 'Create an identity first to manage groups.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          )
        else
          ...groups.map((g) {
            final count = (g['member_count'] as int?) ?? _memberAliases(g).length;
            final aliases = _memberAliases(g);
            return ListTile(
              dense: true,
              leading: const Icon(Icons.groups, size: 20),
              title: Text(g['name'] as String? ?? ''),
              subtitle: Text(
                count == 0
                    ? 'No members'
                    : '$count member${count == 1 ? '' : 's'} · ${aliases.join(', ')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    tooltip: 'Edit group',
                    onPressed: isLoading ? null : () => _showEditDialog(context, g),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    tooltip: 'Delete group',
                    onPressed: isLoading ? null : () => _showRemoveDialog(context, g),
                  ),
                ],
              ),
            );
          }),
        const SizedBox(height: 12),
        if (hasKeys)
          OutlinedButton.icon(
            onPressed: isLoading ? null : () => _showAddDialog(context),
            icon: const Icon(Icons.add),
            label: const Text('Add Group'),
          ),
      ],
    );
  }
}

/// Add/edit group dialog. StatefulWidget so the name controller's lifecycle is
/// owned by State.dispose() (never a closure that disposes after an await).
class _GroupDialog extends StatefulWidget {
  const _GroupDialog({
    required this.title,
    required this.submitLabel,
    required this.contactAliases,
    required this.onSubmit,
    required this.onError,
    required this.onRefresh,
    this.initialName = '',
    this.initialMembers = const [],
  });

  final String title;
  final String submitLabel;
  final String initialName;
  final List<String> initialMembers;
  final List<String> contactAliases;
  final Future<void> Function(String name, List<String> members) onSubmit;
  final void Function(String message) onError;
  final Future<void> Function() onRefresh;

  @override
  State<_GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends State<_GroupDialog> {
  late final TextEditingController _nameCtrl;
  late List<String> _members;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.initialName);
    _members = List<String>.from(widget.initialMembers);
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      unawaited(showMessageDialog(context, 'Validation Error', 'A group name is required.'));
      return;
    }
    Navigator.of(context).pop();
    try {
      await widget.onSubmit(name, _members);
    } catch (e) {
      widget.onError('Failed to save group: $e');
    }
    await widget.onRefresh();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 450,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Group name *', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 16),
              DropdownSearch<String>.multiSelection(
                selectedItems: _members,
                items: (filter, _) => widget.contactAliases,
                popupProps: MultiSelectionPopupProps.menu(
                  showSearchBox: true,
                  checkBoxBuilder: (ctx, _, __, selected) => circleCheckbox(ctx, selected),
                  constraints: const BoxConstraints(maxHeight: 280),
                  searchFieldProps: const TextFieldProps(
                    decoration: InputDecoration(
                      hintText: 'Search contacts…',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                decoratorProps: const DropDownDecoratorProps(
                  decoration: InputDecoration(labelText: 'Members', border: OutlineInputBorder()),
                ),
                onSelected: (values) => setState(() => _members = values),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: Text(widget.submitLabel)),
      ],
    );
  }
}
