import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:veloguard/src/providers/dns_settings_provider.dart';
import 'package:veloguard/src/widgets/adaptive_list_tile.dart';
import 'package:veloguard/src/l10n/app_localizations.dart';

/// DNS settings, limited to what the engine can carry.
///
/// `overrideDns` decides which DNS section the engine receives: this screen's
/// (`dns.enable` / `dns.listen` / `dns.nameservers` / `dns.fallback` /
/// `dns.enhanced_mode`), or the one the profile declares. Without the switch
/// on, the profile wins, which is what "use the DNS my subscription ships"
/// means.
class DnsSettingsScreen extends StatefulWidget {
  const DnsSettingsScreen({super.key});

  @override
  State<DnsSettingsScreen> createState() => _DnsSettingsScreenState();
}

class _DnsSettingsScreenState extends State<DnsSettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);

    return Consumer<DnsSettingsProvider>(
      builder: (context, dnsSettings, child) {
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n?.dnsSettings ?? 'DNS Settings'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.go('/settings'),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildSectionHeader(
                context,
                l10n?.basicSettings ?? 'Basic Settings',
                Icons.settings_outlined,
              ),
              Card(
                elevation: 0,
                color: colorScheme.surfaceContainerLow,
                child: Column(
                  children: [
                    AdaptiveListTile(
                      title: Text(l10n?.overrideDns ?? 'Override DNS'),
                      subtitle: Text(
                        l10n?.overrideDnsDesc ??
                            'Replace the profile DNS section with the settings '
                                'on this page',
                      ),
                      leading: Icon(
                        Icons.dns_outlined,
                        color: colorScheme.primary,
                      ),
                      trailing: Switch.adaptive(
                        value: dnsSettings.overrideDns,
                        onChanged: (v) => dnsSettings.setOverrideDns(v),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    AdaptiveListTile(
                      title: Text(l10n?.dnsStatus ?? 'DNS Status'),
                      subtitle: Text(
                        dnsSettings.enable
                            ? (l10n?.enabled ?? 'Enabled')
                            : (l10n?.disabled ?? 'Disabled'),
                      ),
                      leading: Icon(
                        dnsSettings.enable
                            ? Icons.check_circle_outline
                            : Icons.cancel_outlined,
                        color: dnsSettings.enable
                            ? colorScheme.primary
                            : colorScheme.error,
                      ),
                      trailing: Switch.adaptive(
                        value: dnsSettings.enable,
                        onChanged: (v) => dnsSettings.setEnable(v),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    AdaptiveListTile(
                      title: Text(l10n?.listenAddress ?? 'Listen Address'),
                      subtitle: Text(dnsSettings.listen),
                      leading: Icon(
                        Icons.hearing_outlined,
                        color: colorScheme.primary,
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () => _showEditDialog(
                        context,
                        l10n?.listenAddress ?? 'Listen Address',
                        dnsSettings.listen,
                        (v) => dnsSettings.setListen(v.trim()),
                      ),
                    ),
                  ],
                ),
              ),

              if (!dnsSettings.overrideDns) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.tertiaryContainer.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 20,
                        color: colorScheme.tertiary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Override DNS is off: the engine uses the DNS '
                          'section from the active profile. Everything below '
                          'is applied once the switch is on.',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 24),

              _buildSectionHeader(
                context,
                l10n?.advancedSettings ?? 'Advanced Settings',
                Icons.tune_outlined,
              ),
              Card(
                elevation: 0,
                color: colorScheme.surfaceContainerLow,
                child: Column(
                  children: [
                    AdaptiveListTile(
                      title: const Text('Recursive Resolver'),
                      subtitle: const Text(
                        'Resolve from the DNS root locally (RecurseX) instead '
                        'of forwarding to upstream servers',
                      ),
                      leading: Icon(
                        Icons.hub_outlined,
                        color: colorScheme.primary,
                      ),
                      trailing: Switch.adaptive(
                        value: dnsSettings.useRecursiveResolver,
                        onChanged: (v) =>
                            dnsSettings.setUseRecursiveResolver(v),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    AdaptiveListTile(
                      title: Text(l10n?.dnsMode ?? 'DNS Mode'),
                      subtitle: Text(_getDnsModeText(dnsSettings.dnsMode, l10n)),
                      leading: Icon(
                        Icons.settings_input_component_outlined,
                        color: colorScheme.primary,
                      ),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: DropdownButton<String>(
                          value: dnsSettings.dnsMode,
                          underline: const SizedBox.shrink(),
                          isDense: true,
                          borderRadius: BorderRadius.circular(12),
                          items: const [
                            DropdownMenuItem(
                              value: 'normal',
                              child: Text('Normal'),
                            ),
                            DropdownMenuItem(
                              value: 'fake-ip',
                              child: Text('Fake-IP'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) dnsSettings.setDnsMode(v);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              _buildSectionHeader(
                context,
                l10n?.dnsServers ?? 'DNS Servers',
                Icons.cloud_outlined,
              ),
              Card(
                elevation: 0,
                color: colorScheme.surfaceContainerLow,
                child: Column(
                  children: [
                    AdaptiveListTile(
                      title: Text(l10n?.nameservers ?? 'Nameservers'),
                      subtitle: Text(
                        '${dnsSettings.nameservers.length} ${l10n?.servers ?? 'servers'}',
                      ),
                      leading: Icon(
                        Icons.public_outlined,
                        color: colorScheme.primary,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showListEditor(
                        context,
                        l10n?.nameservers ?? 'Nameservers',
                        dnsSettings.nameservers,
                        (item) => dnsSettings.addNameserver(item),
                        (item) => dnsSettings.removeNameserver(item),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    AdaptiveListTile(
                      title: Text(l10n?.fallbackServers ?? 'Fallback Servers'),
                      subtitle: Text(
                        '${dnsSettings.fallback.length} ${l10n?.servers ?? 'servers'}',
                      ),
                      leading: Icon(
                        Icons.backup_outlined,
                        color: colorScheme.primary,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showListEditor(
                        context,
                        l10n?.fallbackServers ?? 'Fallback Servers',
                        dnsSettings.fallback,
                        (item) => dnsSettings.addFallback(item),
                        (item) => dnsSettings.removeFallback(item),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    IconData icon,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  String _getDnsModeText(String mode, AppLocalizations? l10n) {
    switch (mode) {
      case 'normal':
        return l10n?.normalMode ?? 'Normal Mode';
      case 'fake-ip':
        return l10n?.fakeIpMode ?? 'Fake-IP Mode';
      default:
        return mode;
    }
  }

  void _showEditDialog(
    BuildContext context,
    String title,
    String currentValue,
    Function(String) onSave,
  ) {
    final controller = TextEditingController(text: currentValue);
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: colorScheme.surfaceContainerHighest,
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n?.cancel ?? 'Cancel'),
          ),
          FilledButton(
            onPressed: () {
              onSave(controller.text);
              Navigator.pop(context);
            },
            child: Text(l10n?.save ?? 'Save'),
          ),
        ],
      ),
    );
  }

  void _showListEditor(
    BuildContext context,
    String title,
    List<String> items,
    Function(String) onAdd,
    Function(String) onRemove,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: colorScheme.surfaceContainerLow,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => _ListEditorSheet(
          title: title,
          items: items,
          onAdd: onAdd,
          onRemove: onRemove,
          scrollController: scrollController,
        ),
      ),
    );
  }
}

class _ListEditorSheet extends StatefulWidget {
  final String title;
  final List<String> items;
  final Function(String) onAdd;
  final Function(String) onRemove;
  final ScrollController scrollController;

  const _ListEditorSheet({
    required this.title,
    required this.items,
    required this.onAdd,
    required this.onRemove,
    required this.scrollController,
  });

  @override
  State<_ListEditorSheet> createState() => _ListEditorSheetState();
}

class _ListEditorSheetState extends State<_ListEditorSheet> {
  final _controller = TextEditingController();
  late List<String> _items;

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.items);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return SafeArea(
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 32,
            height: 4,
            decoration: BoxDecoration(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Row(
              children: [
                Icon(Icons.list_outlined, color: colorScheme.primary),
                const SizedBox(width: 12),
                Text(
                  widget.title,
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText:
                          AppLocalizations.of(context)?.addNewItem ??
                          'Add new item...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    onSubmitted: (value) => _addItem(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _addItem,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _items.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.inbox_outlined,
                          size: 64,
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.5,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          AppLocalizations.of(context)?.noDataYet ??
                              'No data yet',
                          style: textTheme.bodyLarge?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: widget.scrollController,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _items.length,
                    itemBuilder: (context, index) {
                      final item = _items[index];
                      return Card(
                        elevation: 0,
                        color: colorScheme.surfaceContainerHigh,
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          title: Text(
                            item,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                          trailing: IconButton(
                            icon: Icon(
                              Icons.delete_outline,
                              color: colorScheme.error,
                            ),
                            onPressed: () => _removeItem(item),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _addItem() {
    final value = _controller.text.trim();
    if (value.isNotEmpty && !_items.contains(value)) {
      widget.onAdd(value);
      setState(() {
        _items.add(value);
      });
      _controller.clear();
    }
  }

  void _removeItem(String item) {
    widget.onRemove(item);
    setState(() {
      _items.remove(item);
    });
  }
}
