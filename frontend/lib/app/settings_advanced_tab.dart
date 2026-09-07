import 'dart:convert';

import 'package:flutter/material.dart';

import '../bridge/bridge.gen.dart';
import '../bridge/filechooser.dart';

class SettingsAdvancedTab extends StatefulWidget {
  const SettingsAdvancedTab({
    super.key,
    required this.onGetSettings,
    required this.onSetSetting,
    required this.onExportProfile,
    required this.onImportProfile,
    required this.onRefresh,
    required this.onError,
  });

  final Future<String> Function() onGetSettings;
  final Future<void> Function(String key, String value) onSetSetting;
  final Future<void> Function() onExportProfile;
  final Future<void> Function() onImportProfile;
  final Future<void> Function() onRefresh;
  final void Function(String message) onError;

  @override
  State<SettingsAdvancedTab> createState() => _SettingsAdvancedTabState();
}

class _SettingsAdvancedTabState extends State<SettingsAdvancedTab> {
  Map<String, dynamic> _settings = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    try {
      final settingsJson = await widget.onGetSettings();
      if (!mounted) return;
      setState(() {
        _settings = jsonDecode(settingsJson) as Map<String, dynamic>;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      widget.onError('Failed to load settings: $e');
      setState(() => _isLoading = false);
    }
  }

  Future<void> _saveSetting(String key, String value) async {
    try {
      await widget.onSetSetting(key, value);
      await _loadData();
      if (key == 'data_path' || key == 'key_path' || key == 'conf_path') {
        await widget.onRefresh();
      }
    } catch (e) {
      widget.onError('Failed to save setting: $e');
    }
  }

  Future<void> _pickDirectory(String key, String label) async {
    try {
      final path = await fileChooserService.pickDirectory('Select $label');
      if (path == null) return;
      await _saveSetting(key, path);
    } catch (e) {
      widget.onError('Failed to open directory chooser: $e');
    }
  }

  Future<void> _pickFile(String key, String label) async {
    try {
      final path = await fileChooserService.pickFile('Select $label');
      if (path == null) return;
      await _saveSetting(key, path);
    } catch (e) {
      widget.onError('Failed to open file chooser: $e');
    }
  }

  void _showEditDialog(BuildContext context, String key, String label, {List<String>? options}) {
    final currentValue = _settings[key]?.toString() ?? '';

    if (options != null) {
      _showDropdownDialog(context, key, label, options, currentValue);
      return;
    }

    // Text field dialog for string settings (identity name, etc.)
    showDialog(
      context: context,
      builder: (_) => _AdvancedTextEditDialog(
        label: label,
        initialValue: currentValue,
        onSave: (v) => _saveSetting(key, v),
      ),
    );
  }

  void _showDropdownDialog(BuildContext context, String key, String label, List<String> options, String currentValue) {
    var selected = currentValue;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Edit $label'),
          content: DropdownButtonFormField<String>(
            initialValue: options.contains(selected) ? selected : options.first,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
            items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
            onChanged: (v) {
              if (v == null) return;
              setDialogState(() => selected = v);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _saveSetting(key, selected);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  static const _autoLockOptions = <int>[0, 5, 15, 30, 60];

  String _autoLockLabel(int minutes) {
    if (minutes <= 0) return 'Off';
    return '$minutes min';
  }

  void _showAutoLockDialog(BuildContext context, int currentMinutes) {
    var selected = _autoLockOptions.contains(currentMinutes) ? currentMinutes : 15;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Auto-lock'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Clear the in-memory passphrase after this many minutes of inactivity. You will be prompted to unlock again on next use.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: selected,
                decoration: const InputDecoration(
                  labelText: 'Idle timeout',
                  border: OutlineInputBorder(),
                ),
                items: _autoLockOptions
                    .map((m) => DropdownMenuItem(value: m, child: Text(_autoLockLabel(m))))
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setDialogState(() => selected = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                _saveSetting('auto_lock_minutes', selected.toString());
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setCloudServer(String url) async {
    try {
      await cloudService.setServerURL(url);
      await _loadData();
    } catch (e) {
      widget.onError('Failed to set cloud server: $e');
    }
  }

  void _showCloudServerDialog(BuildContext context, String currentValue) {
    showDialog(
      context: context,
      builder: (_) => _CloudServerDialog(
        initialValue: currentValue,
        onSave: _setCloudServer,
      ),
    );
  }

  static const _syncDirPatterns = [
    'dropbox', 'google drive', 'googledrive', 'onedrive',
    'icloud', 'syncthing', 'nextcloud', 'mega',
  ];

  bool _looksLikeSyncDir(String path) {
    final lower = path.toLowerCase();
    return _syncDirPatterns.any((p) => lower.contains(p));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final confPath = _settings['conf_path']?.toString() ?? '';
    final dataPath = _settings['data_path']?.toString() ?? '';
    final keyPath = _settings['key_path']?.toString() ?? '';
    final keystoreType = _settings['keystore']?.toString() ?? 'keychain';
    final defaultIdentity = _settings['default_identity']?.toString() ?? '';
    final verbose = _settings['verbose'] == true;
    final cloudBaseUrl = _settings['cloud_base_url']?.toString() ?? '';
    final autoLockMin = (_settings['auto_lock_minutes'] is int)
        ? _settings['auto_lock_minutes'] as int
        : 15;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ExpansionTile(
          title: Text('Configuration', style: theme.textTheme.titleSmall),
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          children: [
            _settingTile(context, theme, 'Identity', defaultIdentity.isEmpty ? '(primary)' : defaultIdentity, () {
              _showEditDialog(context, 'default_identity', 'Default Identity');
            }),
            // Default output format is always the icfx container (age isn't
            // offered as a standing default — it's a per-file encrypt option).
            // No picker shown.
            _settingTile(context, theme, 'Keystore', keystoreType, () {
              _showEditDialog(context, 'keystore', 'Keystore', options: ['keychain', 'file']);
            }),
            _settingTile(context, theme, 'Auto-lock', _autoLockLabel(autoLockMin), () {
              _showAutoLockDialog(context, autoLockMin);
            }),
            SwitchListTile(
              dense: true,
              title: const Text('Verbose'),
              value: verbose,
              onChanged: (v) => _saveSetting('verbose', v.toString()),
            ),
            _settingTile(
              context,
              theme,
              'Cloud Server',
              cloudBaseUrl.isEmpty ? 'default' : cloudBaseUrl,
              () => _showCloudServerDialog(context, cloudBaseUrl),
              resetable: cloudBaseUrl.isNotEmpty,
              onReset: () => _setCloudServer(''),
            ),
          ],
        ),

        ExpansionTile(
          title: Text('Paths', style: theme.textTheme.titleSmall),
          tilePadding: EdgeInsets.zero,
          childrenPadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          children: [
            _settingTile(context, theme, 'Config File', confPath.isEmpty ? 'default' : confPath, () => _pickFile('conf_path', 'Config File'), resetable: confPath.isNotEmpty, onReset: () => _saveSetting('conf_path', '')),
            _settingTile(context, theme, 'Data Directory', dataPath.isEmpty ? 'default' : dataPath, () => _pickDirectory('data_path', 'Data Directory'), resetable: dataPath.isNotEmpty, onReset: () => _saveSetting('data_path', '')),
            _settingTile(context, theme, 'Key Directory', keyPath.isEmpty ? 'default' : keyPath, () => _pickDirectory('key_path', 'Key Directory'), resetable: keyPath.isNotEmpty, onReset: () => _saveSetting('key_path', '')),
            if (keyPath.isNotEmpty && _looksLikeSyncDir(keyPath))
              Container(
                margin: const EdgeInsets.only(top: 4, bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning, size: 18, color: theme.colorScheme.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Key path appears to be in a sync folder. Private keys should never be synced.',
                        style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onErrorContainer),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),

        const Divider(height: 24),

        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('Profile', style: theme.textTheme.titleSmall),
        ),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => widget.onExportProfile(),
            icon: const Icon(Icons.backup),
            label: const Text('Export Profile'),
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => widget.onImportProfile(),
            icon: const Icon(Icons.restore),
            label: const Text('Import Profile'),
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
            ),
          ),
        ),
      ],
    );
  }

  Widget _settingTile(BuildContext context, ThemeData theme, String label, String value, VoidCallback onTap, {bool resetable = false, VoidCallback? onReset}) {
    return ListTile(
      dense: true,
      title: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (resetable && onReset != null)
            IconButton(
              icon: const Icon(Icons.restore, size: 18),
              tooltip: 'Reset to Default',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              onPressed: onReset,
            ),
          if (resetable && onReset != null)
            const SizedBox(width: 4),
          Flexible(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                color: value == 'default' || value == '(primary)'
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.chevron_right, size: 20),
        ],
      ),
      onTap: onTap,
    );
  }
}

class _CloudServerDialog extends StatefulWidget {
  final String initialValue;
  final Future<void> Function(String value) onSave;

  const _CloudServerDialog({
    required this.initialValue,
    required this.onSave,
  });

  @override
  State<_CloudServerDialog> createState() => _CloudServerDialogState();
}

class _CloudServerDialogState extends State<_CloudServerDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final value = _ctrl.text.trim();
    Navigator.of(context).pop();
    widget.onSave(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Cloud Server'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Server URL',
              hintText: 'https://cloud.example.com',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 8),
          Text(
            'Leave empty for the default server (cloud.instacrypt.io).',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Text(
            'Changing servers signs you out on this device. Your local data stays; sync starts fresh against the new server.',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _AdvancedTextEditDialog extends StatefulWidget {
  final String label;
  final String initialValue;
  final Future<void> Function(String value) onSave;

  const _AdvancedTextEditDialog({
    required this.label,
    required this.initialValue,
    required this.onSave,
  });

  @override
  State<_AdvancedTextEditDialog> createState() => _AdvancedTextEditDialogState();
}

class _AdvancedTextEditDialogState extends State<_AdvancedTextEditDialog> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit ${widget.label}'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        decoration: InputDecoration(
          labelText: widget.label,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (v) {
          Navigator.of(context).pop();
          widget.onSave(v);
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop();
            widget.onSave(_ctrl.text);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
