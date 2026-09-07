import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../bridge/bridge.gen.dart';
import 'import_confirm.dart' show ImportOutcome;
import 'settings_keys_tab.dart';
import 'settings_contacts_tab.dart';
import 'settings_groups_tab.dart';
import 'settings_cloud_tab.dart';
import 'settings_advanced_tab.dart';

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    this.initialTab = 0,
    required this.hasKeys,
    required this.isLoading,
    required this.contacts,
    required this.identities,
    required this.scrollController,
    required this.onCreateKeys,
    required this.onRemoveIdentity,
    required this.onSetDefaultIdentity,
    required this.onRevokeIdentity,
    required this.onRotateIdentity,
    required this.onConfirmContactImport,
    required this.onEditIdentity,
    required this.onToggleHWKey,
    required this.onImportIdentity,
    required this.onShowIdentity,
    required this.onExportLock,
    required this.onExportLockQR,
    required this.onExportIdentity,
    required this.onAddContact,
    required this.onRemoveContact,
    required this.onEditContact,
    required this.onShowContact,
    required this.onExportContactLock,
    required this.onExportContactLockQR,
    required this.onImportLockFile,
    required this.onImportLockQR,
    required this.onImportLockQRPart,
    required this.onGetSettings,
    required this.onSetSetting,
    required this.onExportProfile,
    required this.onImportProfile,
    required this.groups,
    required this.onAddGroup,
    required this.onEditGroup,
    required this.onRemoveGroup,
    required this.onRefresh,
    this.showBell = false,
    this.unseenNotifications = 0,
    this.onOpenNotifications,
  });

  /// Tab to open on: 0 Identities, 1 Contacts, 2 Groups, 3 Cloud, 4 Advanced.
  final int initialTab;
  final bool hasKeys;
  final bool isLoading;
  final List<Map<String, dynamic>> contacts;
  final List<Map<String, dynamic>> identities;
  final ScrollController scrollController;
  final Future<void> Function() onCreateKeys;
  final Future<void> Function(String name) onRemoveIdentity;
  final Future<void> Function(String name) onSetDefaultIdentity;
  final Future<void> Function(String name) onRevokeIdentity;
  final Future<void> Function(String name, String alias, String email, String firstName, String lastName) onRotateIdentity;
  final Future<void> Function(String token) onConfirmContactImport;
  final Future<void> Function(String name, String alias, String email, String firstName, String lastName) onEditIdentity;
  final Future<void> Function(String name, bool enable) onToggleHWKey;
  final Future<void> Function() onImportIdentity;
  final Future<String> Function(String name) onShowIdentity;
  final Future<String> Function(String name) onExportLock;
  final Future<String> Function(String name) onExportLockQR;
  final Future<void> Function(String name) onExportIdentity;
  final Future<void> Function(String alias, String nickname, String firstName, String lastName, String email, String encPubKey, String signPubKey, String fingerprint) onAddContact;
  final Future<void> Function(String alias) onRemoveContact;
  final Future<void> Function(String alias, String nickname, String firstName, String lastName, String email, String encPubKey, String signPubKey, String fingerprint) onEditContact;
  final Future<String> Function(String alias) onShowContact;
  final Future<String> Function(String alias) onExportContactLock;
  final Future<String> Function(String alias) onExportContactLockQR;
  final Future<ImportOutcome> Function(String path, String alias) onImportLockFile;
  final Future<void> Function(String qrData, String alias) onImportLockQR;
  final Future<QRPartResult> Function(String partJSON, String alias) onImportLockQRPart;
  final Future<String> Function() onGetSettings;
  final Future<void> Function(String key, String value) onSetSetting;
  final Future<void> Function() onExportProfile;
  final Future<void> Function() onImportProfile;
  final List<Map<String, dynamic>> groups;
  final Future<void> Function(String name, List<String> memberAliases) onAddGroup;
  final Future<void> Function(String id, String name, List<String> memberAliases) onEditGroup;
  final Future<void> Function(String id) onRemoveGroup;
  final Future<({List<Map<String, dynamic>> identities, List<Map<String, dynamic>> contacts, List<Map<String, dynamic>> groups, bool hasKeys})> Function() onRefresh;

  /// Bell (cloud notifications) — visible only when cloud is enabled.
  final bool showBell;
  final int unseenNotifications;
  final void Function()? onOpenNotifications;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> with SingleTickerProviderStateMixin {
  late List<Map<String, dynamic>> _identities;
  late List<Map<String, dynamic>> _contacts;
  late List<Map<String, dynamic>> _groups;
  late bool _hasKeys;

  String? _errorMessage;
  String? _statusMessage;

  late final TabController _tabController;
  // Cloud enabled + signed in — gates the contacts tab's connection icons.
  bool _cloudReady = false;
  final _keysSearchController = TextEditingController();
  final _contactsSearchController = TextEditingController();
  String _keysSearchQuery = '';
  String _contactsSearchQuery = '';

  void _setError(String message) {
    setState(() {
      _errorMessage = message;
      _statusMessage = null;
    });
  }

  void _clearError() {
    setState(() => _errorMessage = null);
  }

  // Success/status counterpart to the error banner (green, same placement).
  void _setStatus(String message) {
    setState(() {
      _statusMessage = message;
      _errorMessage = null;
    });
  }

  void _clearStatus() {
    setState(() => _statusMessage = null);
  }

  @override
  void initState() {
    super.initState();
    _identities = widget.identities;
    _contacts = widget.contacts;
    _groups = widget.groups;
    _hasKeys = widget.hasKeys;
    _tabController = TabController(length: 5, vsync: this, initialIndex: widget.initialTab);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) setState(() {});
    });
    _keysSearchController.addListener(() {
      setState(() => _keysSearchQuery = _keysSearchController.text);
    });
    _contactsSearchController.addListener(() {
      setState(() => _contactsSearchQuery = _contactsSearchController.text);
    });
    unawaited(_loadCloudReady());
  }

  Future<void> _loadCloudReady() async {
    try {
      final st = jsonDecode(await cloudService.cloudUIState()) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() =>
          _cloudReady = st['enabled'] == true && st['signed_in'] == true);
    } catch (_) {
      // Cloud state unavailable — icons simply stay hidden.
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _keysSearchController.dispose();
    _contactsSearchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final data = await widget.onRefresh();
    if (!mounted) return;
    setState(() {
      _identities = data.identities;
      _contacts = data.contacts;
      _groups = data.groups;
      _hasKeys = data.hasKeys;
    });
  }

  List<Map<String, dynamic>> get _filteredIdentities {
    if (_keysSearchQuery.isEmpty) return _identities;
    final q = _keysSearchQuery.toLowerCase();
    return _identities.where((id) =>
      (id['name'] as String? ?? '').toLowerCase().contains(q)
    ).toList();
  }

  List<Map<String, dynamic>> get _filteredContacts {
    if (_contactsSearchQuery.isEmpty) return _contacts;
    final q = _contactsSearchQuery.toLowerCase();
    return _contacts.where((c) =>
      (c['alias'] as String? ?? '').toLowerCase().contains(q)
    ).toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Search only applies to the Identities/Contacts tabs (0/1); the Cloud (2)
    // and Advanced (3) tabs have no list to filter.
    final isAdvancedTab = _tabController.index >= 2;

    final searchController = _tabController.index == 0
        ? _keysSearchController
        : _contactsSearchController;
    final searchHint = _tabController.index == 0
        ? 'Search lock & key pairs...'
        : 'Search contacts...';

    final tabBar = TabBar(
      controller: _tabController,
      tabs: const [
        Tab(icon: Icon(Icons.vpn_key), text: 'Identities'),
        Tab(icon: Icon(Icons.people), text: 'Contacts'),
        Tab(icon: Icon(Icons.groups), text: 'Groups'),
        Tab(icon: Icon(Icons.cloud), text: 'Cloud'),
        Tab(icon: Icon(Icons.tune), text: 'Advanced'),
      ],
    );
    // The sheet's actual background — the pinned tab bar paints it so
    // scrolling content disappears underneath instead of bleeding through.
    final sheetColor = theme.bottomSheetTheme.backgroundColor ??
        theme.colorScheme.surfaceContainerLow;

    // CustomScrollView on the DraggableScrollableSheet's controller: the
    // handle + title scroll away, the tab bar pins to the top, and sheet
    // drag/expand keeps working since the one scrollable owns the controller.
    return CustomScrollView(
      controller: widget.scrollController,
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 32,
                    height: 4,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Settings',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    if (widget.showBell && widget.onOpenNotifications != null)
                      Badge(
                        isLabelVisible: widget.unseenNotifications > 0,
                        label: Text('${widget.unseenNotifications}'),
                        child: IconButton(
                          icon: const Icon(Icons.notifications_outlined),
                          tooltip: 'Cloud notifications',
                          onPressed: widget.onOpenNotifications,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),

        // Tab bar — pinned: stays visible while the content scrolls.
        SliverPersistentHeader(
          pinned: true,
          delegate: _PinnedTabBar(tabBar: tabBar, color: sheetColor),
        ),

        SliverPadding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
        // Search bar (hidden on Advanced tab)
        if (!isAdvancedTab) ...[
          TextField(
            controller: searchController,
            decoration: InputDecoration(
              hintText: searchHint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        if (_tabController.index == 0) {
                          _keysSearchController.clear();
                        } else {
                          _contactsSearchController.clear();
                        }
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],

        // Error banner
        if (_errorMessage != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline, size: 20, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _errorMessage!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: theme.colorScheme.onErrorContainer),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _clearError,
                ),
              ],
            ),
          ),

        // Status banner (green sibling of the error banner)
        if (_statusMessage != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(Icons.check_circle_outline, size: 20, color: Colors.green),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _statusMessage!,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18, color: Colors.green),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: _clearStatus,
                ),
              ],
            ),
          ),

        // Tab content
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: _buildTabContent(),
        ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabContent() {
    switch (_tabController.index) {
      case 0:
        return SettingsKeysTab(
          key: const ValueKey('keys'),
          identities: _filteredIdentities,
          hasKeys: _hasKeys,
          isLoading: widget.isLoading,
          searchQuery: _keysSearchQuery,
          onCreateKeys: widget.onCreateKeys,
          onRemoveIdentity: widget.onRemoveIdentity,
          onSetDefaultIdentity: widget.onSetDefaultIdentity,
          onRevokeIdentity: widget.onRevokeIdentity,
          onRotateIdentity: widget.onRotateIdentity,
          onEditIdentity: widget.onEditIdentity,
          onToggleHWKey: widget.onToggleHWKey,
          onImportIdentity: widget.onImportIdentity,
          onShowIdentity: widget.onShowIdentity,
          onExportLock: widget.onExportLock,
          onExportLockQR: widget.onExportLockQR,
          onExportIdentity: widget.onExportIdentity,
          onRefresh: _refresh,
          onError: _setError,
          onStatus: _setStatus,
        );
      case 1:
        return SettingsContactsTab(
          key: const ValueKey('contacts'),
          contacts: _filteredContacts,
          hasKeys: _hasKeys,
          isLoading: widget.isLoading,
          searchQuery: _contactsSearchQuery,
          onAddContact: widget.onAddContact,
          onRemoveContact: widget.onRemoveContact,
          onEditContact: widget.onEditContact,
          onShowContact: widget.onShowContact,
          onExportContactLock: widget.onExportContactLock,
          onExportContactLockQR: widget.onExportContactLockQR,
          onImportLockFile: widget.onImportLockFile,
          onImportLockQR: widget.onImportLockQR,
          onImportLockQRPart: widget.onImportLockQRPart,
          onConfirmContactImport: widget.onConfirmContactImport,
          onRefresh: _refresh,
          onError: _setError,
          onStatus: _setStatus,
          cloudReady: _cloudReady,
        );
      case 2:
        return SettingsGroupsTab(
          key: const ValueKey('groups'),
          groups: _groups,
          contacts: _contacts,
          hasKeys: _hasKeys,
          isLoading: widget.isLoading,
          onAddGroup: widget.onAddGroup,
          onEditGroup: widget.onEditGroup,
          onRemoveGroup: widget.onRemoveGroup,
          onRefresh: _refresh,
          onError: _setError,
          onStatus: _setStatus,
        );
      case 3:
        return SettingsCloudTab(
          key: const ValueKey('cloud'),
          hasKeys: _hasKeys,
          onError: _setError,
          onStatus: _setStatus,
          onSynced: _refresh,
        );
      default:
        return SettingsAdvancedTab(
          key: const ValueKey('advanced'),
          onGetSettings: widget.onGetSettings,
          onSetSetting: widget.onSetSetting,
          onExportProfile: widget.onExportProfile,
          onImportProfile: widget.onImportProfile,
          onRefresh: _refresh,
          onError: _setError,
        );
    }
  }
}

/// _PinnedTabBar keeps the settings tab bar visible at the top of the sheet
/// while the content scrolls beneath it.
class _PinnedTabBar extends SliverPersistentHeaderDelegate {
  const _PinnedTabBar({required this.tabBar, required this.color});

  final TabBar tabBar;
  final Color color;

  @override
  double get minExtent => tabBar.preferredSize.height;

  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    // Opaque backing in the sheet's own color so scrolled content
    // disappears under the pinned bar instead of showing through.
    return ColoredBox(color: color, child: tabBar);
  }

  @override
  bool shouldRebuild(_PinnedTabBar oldDelegate) =>
      oldDelegate.tabBar != tabBar || oldDelegate.color != color;
}
