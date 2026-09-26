import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:arcadiaplus/src/providers/dns_settings_provider.dart';
import 'package:arcadiaplus/src/providers/general_settings_provider.dart';
import 'package:arcadiaplus/src/services/dns_upstreams.dart';
import 'package:arcadiaplus/src/services/system_dns_service.dart';
import 'package:arcadiaplus/src/widgets/adaptive_list_tile.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';

/// Display name for a `dns.enhanced_mode` value.
///
/// `redir-host` and `normal` are one behaviour under two names — the spelling
/// mihomo profiles use, and the one this engine canonicalises to — so both stay
/// visible instead of one being quietly renamed out from under the profiles
/// that already say it.
String _modeLabel(String mode) => switch (mode) {
  'redir-host' => 'Redir-Host',
  'fake-ip' => 'Fake-IP',
  'normal' => 'Normal',
  _ => mode,
};

/// What the selected mode actually does, rather than a second copy of its name:
/// the two spellings of one behaviour look like two behaviours otherwise.
String _modeDescription(String mode, AppLocalizations? l10n) =>
    mode == 'fake-ip'
    ? (l10n?.fakeIpMode ?? 'Fake-IP')
    : (l10n?.normalMode ?? 'Normal');

String _presetTagLabel(AppLocalizations? l10n, DnsPresetTag tag) =>
    switch (tag) {
      DnsPresetTag.recommended => l10n?.dnsPresetRecommended ?? 'Recommended',
      DnsPresetTag.privacy => l10n?.dnsPresetPrivacy ?? 'Privacy',
      DnsPresetTag.family => l10n?.dnsPresetFamily ?? 'Family filter',
      DnsPresetTag.domestic => l10n?.dnsPresetDomestic ?? 'Mainland China',
    };

/// DNS settings, limited to what the engine can carry.
///
/// `overrideDns` decides which DNS section the engine receives: this screen's
/// (`dns.enable` / `dns.listen` / `dns.nameservers` / `dns.fallback` /
/// `dns.enhanced_mode`), or the one the profile declares. Without the switch
/// on, the profile wins, which is what "use the DNS my subscription ships"
/// means.
///
/// Everything DNS-shaped lives here, including the switches that are about how
/// the engine resolves rather than which server it asks — appending the
/// platform's own resolvers, and answering from the DNS root locally. They used
/// to sit under "advanced config", which sent a reader looking in two places
/// for one subject.
class DnsSettingsScreen extends StatelessWidget {
  const DnsSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n?.dnsSettings ?? 'DNS Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/settings'),
        ),
      ),
      body: Consumer<DnsSettingsProvider>(
        builder: (context, dnsSettings, child) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _SectionHeader(
                title: l10n?.basicSettings ?? 'Basic Settings',
                icon: Icons.settings_outlined,
              ),
              Card(
                elevation: 0,
                child: Column(
                  children: [
                    AdaptiveListTile(
                      title: Text(l10n?.overrideDns ?? 'Override DNS'),
                      subtitle: Text(
                        l10n?.overrideDnsDesc ??
                            'Replace the profile DNS section with the settings '
                                'on this page',
                      ),
                      leading: _leadingIcon(context, Icons.dns_outlined),
                      trailing: Switch.adaptive(
                        value: dnsSettings.overrideDns,
                        onChanged: dnsSettings.setOverrideDns,
                      ),
                    ),
                    _divider(),
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
                            ? Theme.of(context).colorScheme.primary
                            : Theme.of(context).colorScheme.error,
                      ),
                      trailing: Switch.adaptive(
                        value: dnsSettings.enable,
                        onChanged: dnsSettings.setEnable,
                      ),
                    ),
                    _divider(),
                    AdaptiveListTile(
                      title: Text(l10n?.listenAddress ?? 'Listen Address'),
                      subtitle: Text(
                        l10n?.listenAddressDesc == null
                            ? dnsSettings.listen
                            : '${dnsSettings.listen}\n'
                                  '${l10n!.listenAddressDesc}',
                      ),
                      isThreeLine: l10n?.listenAddressDesc != null,
                      leading: _leadingIcon(context, Icons.hearing_outlined),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap: () => _promptForText(
                        context,
                        l10n?.listenAddress ?? 'Listen Address',
                        dnsSettings.listen,
                        (value) => dnsSettings.setListen(value.trim()),
                      ),
                    ),
                  ],
                ),
              ),

              if (!dnsSettings.overrideDns) ...[
                const SizedBox(height: 12),
                _Notice(
                  message:
                      l10n?.dnsOverrideOffNotice ??
                      'Override DNS is off: the engine uses the DNS section '
                          'from the active profile.',
                ),
              ],

              const SizedBox(height: 24),

              _SectionHeader(
                title: l10n?.dnsBehaviour ?? 'DNS Behaviour',
                icon: Icons.tune_outlined,
              ),
              Card(
                elevation: 0,
                child: Column(
                  children: [
                    const _AppendSystemDnsTile(),
                    _divider(),
                    AdaptiveListTile(
                      title: Text(
                        l10n?.recursiveResolver ?? 'Recursive Resolver',
                      ),
                      subtitle: Text(
                        l10n?.recursiveResolverDesc ??
                            'Resolve from the DNS root locally (RecurseX) '
                                'instead of forwarding to upstream servers',
                      ),
                      leading: _leadingIcon(context, Icons.hub_outlined),
                      trailing: Switch.adaptive(
                        value: dnsSettings.useRecursiveResolver,
                        onChanged: dnsSettings.setUseRecursiveResolver,
                      ),
                    ),
                    _divider(),
                    AdaptiveListTile(
                      title: Text(l10n?.dnsMode ?? 'DNS Mode'),
                      subtitle: Text(
                        _modeDescription(dnsSettings.dnsMode, l10n),
                      ),
                      leading: _leadingIcon(
                        context,
                        Icons.settings_input_component_outlined,
                      ),
                      trailing: _ModePicker(
                        value: dnsSettings.dnsMode,
                        onChanged: dnsSettings.setDnsMode,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              _SectionHeader(
                title: l10n?.dnsServers ?? 'DNS Servers',
                icon: Icons.cloud_outlined,
              ),
              Card(
                elevation: 0,
                child: Column(
                  children: [
                    AdaptiveListTile(
                      title: Text(l10n?.nameservers ?? 'Nameservers'),
                      subtitle: Text(
                        '${dnsSettings.nameservers.length} '
                        '${l10n?.servers ?? 'servers'}',
                      ),
                      leading: _leadingIcon(context, Icons.public_outlined),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showUpstreamEditor(
                        context,
                        l10n?.nameservers ?? 'Nameservers',
                        dnsSettings.nameservers,
                        dnsSettings.addNameservers,
                        dnsSettings.removeNameserver,
                      ),
                    ),
                    _divider(),
                    AdaptiveListTile(
                      title: Text(l10n?.fallbackServers ?? 'Fallback Servers'),
                      subtitle: Text(
                        '${dnsSettings.fallback.length} '
                        '${l10n?.servers ?? 'servers'}',
                      ),
                      leading: _leadingIcon(context, Icons.backup_outlined),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _showUpstreamEditor(
                        context,
                        l10n?.fallbackServers ?? 'Fallback Servers',
                        dnsSettings.fallback,
                        dnsSettings.addFallbacks,
                        dnsSettings.removeFallback,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }

  static Widget _leadingIcon(BuildContext context, IconData icon) =>
      Icon(icon, color: Theme.of(context).colorScheme.primary);

  static Widget _divider() =>
      const Divider(height: 1, indent: 16, endIndent: 16);
}

/// `append system DNS`, which only exists where the platform lets an
/// application read its resolvers.
///
/// The switch is not offered at all where it could not do anything: a toggle
/// that changes nothing is a claim the app cannot keep. Where it is offered,
/// the platform list is invalidated on every change so the next config build
/// reads it again instead of reusing a reading taken before the switch moved.
class _AppendSystemDnsTile extends StatelessWidget {
  const _AppendSystemDnsTile();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    if (!SystemDnsService.isSupported) {
      return AdaptiveListTile(
        title: Text(l10n?.appendSystemDns ?? 'Append System DNS'),
        subtitle: Text(
          l10n?.appendSystemDnsUnsupported ??
              'This platform does not expose its resolvers to applications, '
                  'so this setting has no effect',
        ),
        leading: Icon(
          Icons.add_circle_outline,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        trailing: Switch.adaptive(value: false, onChanged: null),
        enabled: false,
      );
    }

    return Consumer<GeneralSettingsProvider>(
      builder: (context, generalSettings, child) => AdaptiveListTile(
        title: Text(l10n?.appendSystemDns ?? 'Append System DNS'),
        subtitle: Text(
          l10n?.appendSystemDnsDesc ?? 'Append system DNS to nameserver',
        ),
        leading: Icon(
          Icons.add_circle_outline,
          color: Theme.of(context).colorScheme.primary,
        ),
        trailing: Switch.adaptive(
          value: generalSettings.appendSystemDns,
          onChanged: (value) {
            generalSettings.setAppendSystemDns(value);
            SystemDnsService.instance.invalidate();
          },
        ),
      ),
    );
  }
}

/// The `dns.enhanced_mode` picker.
///
/// Its items come from the store's vocabulary rather than a second copy of it:
/// a picker whose items drift from the values the store accepts offers a choice
/// that does nothing when it is taken.
class _ModePicker extends StatelessWidget {
  const _ModePicker({required this.value, required this.onChanged});

  final String value;
  final void Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: DropdownButton<String>(
        value: value,
        underline: const SizedBox.shrink(),
        isDense: true,
        borderRadius: BorderRadius.circular(12),
        dropdownColor: colorScheme.surfaceContainerHigh,
        items: [
          for (final mode in DnsSettingsProvider.modes)
            DropdownMenuItem(value: mode, child: Text(_modeLabel(mode))),
        ],
        onChanged: (next) {
          if (next != null) onChanged(next);
        },
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 20, color: colorScheme.tertiary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

/// The `DoH` / `DoT` / `UDP` badge shown next to an upstream address.
class UpstreamKindBadge extends StatelessWidget {
  const UpstreamKindBadge(this.kind, {super.key});

  final DnsUpstreamKind kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (kind) {
      DnsUpstreamKind.doh || DnsUpstreamKind.doh3 => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
      ),
      DnsUpstreamKind.dot || DnsUpstreamKind.quic => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      DnsUpstreamKind.plain => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
      ),
      DnsUpstreamKind.system || DnsUpstreamKind.dhcp => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      DnsUpstreamKind.unknown => (
        scheme.errorContainer,
        scheme.onErrorContainer,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        kind.badge,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// One text field in a dialog, committing on save rather than per keystroke.
void _promptForText(
  BuildContext context,
  String title,
  String currentValue,
  void Function(String) onSave,
) {
  final controller = TextEditingController(text: currentValue);
  final colorScheme = Theme.of(context).colorScheme;
  final l10n = AppLocalizations.of(context);

  showDialog<void>(
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
        onSubmitted: (value) {
          onSave(value);
          Navigator.pop(context);
        },
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
  ).whenComplete(controller.dispose);
}

void _showUpstreamEditor(
  BuildContext context,
  String title,
  List<String> items,
  Future<void> Function(Iterable<String>) onAdd,
  Future<void> Function(String) onRemove,
) {
  final colorScheme = Theme.of(context).colorScheme;

  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: colorScheme.surfaceContainerLow,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) => _UpstreamEditorSheet(
        title: title,
        items: items,
        onAdd: onAdd,
        onRemove: onRemove,
        scrollController: scrollController,
      ),
    ),
  );
}

class _UpstreamEditorSheet extends StatefulWidget {
  const _UpstreamEditorSheet({
    required this.title,
    required this.items,
    required this.onAdd,
    required this.onRemove,
    required this.scrollController,
  });

  final String title;
  final List<String> items;
  final Future<void> Function(Iterable<String>) onAdd;
  final Future<void> Function(String) onRemove;
  final ScrollController scrollController;

  @override
  State<_UpstreamEditorSheet> createState() => _UpstreamEditorSheetState();
}

class _UpstreamEditorSheetState extends State<_UpstreamEditorSheet> {
  final _controller = TextEditingController();
  late List<String> _items;
  bool _unrecognisedEntry = false;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.items);
  }

  @override
  void didUpdateWidget(_UpstreamEditorSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The store is the source of truth and this sheet writes through it, so a
    // stored list that changed underneath (a migration on first load, or a
    // rejected write) is mirrored rather than left showing something that is
    // not what will be used.
    if (!listEquals(oldWidget.items, widget.items)) {
      _items = List.of(widget.items);
    }
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
    final l10n = AppLocalizations.of(context);

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
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
            child: Row(
              children: [
                Icon(Icons.list_outlined, color: colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.title,
                    style: textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${_items.length}',
                  style: textTheme.labelLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          _buildPresets(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText:
                          l10n?.dnsUpstreamHint ?? '1.1.1.1 · tls://1.1.1.1',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    autocorrect: false,
                    enableSuggestions: false,
                    onChanged: _onFieldChanged,
                    onSubmitted: (_) => _addFromField(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _addFromField,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          if (_unrecognisedEntry)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.help_outline, size: 16, color: colorScheme.error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n?.dnsUpstreamUnknown ?? '',
                      style: textTheme.bodySmall?.copyWith(
                        color: colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: 1, indent: 16, endIndent: 16),
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
                          l10n?.noDataYet ?? 'No data yet',
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
                        margin: const EdgeInsets.only(top: 8),
                        child: ListTile(
                          title: Text(
                            item,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              UpstreamKindBadge(classifyUpstream(item)),
                              IconButton(
                                icon: Icon(
                                  Icons.delete_outline,
                                  color: colorScheme.error,
                                ),
                                onPressed: () => _removeItem(item),
                              ),
                            ],
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

  /// The presets, grouped by what they are for.
  ///
  /// A row of a dozen chips in one alphabet tells a reader nothing; four short
  /// rows tell them which one they want. A preset already in the list is shown
  /// checked and cannot be added twice, because adding it would do nothing.
  Widget _buildPresets(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 8),
          child: Row(
            children: [
              Icon(Icons.bolt_outlined, size: 16, color: colorScheme.primary),
              const SizedBox(width: 6),
              Text(
                l10n?.dnsQuickAdd ?? 'Quick add',
                style: textTheme.labelLarge?.copyWith(
                  color: colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 92,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final tag in DnsPresetTag.values)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _presetTagLabel(l10n, tag),
                        style: textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final preset in dnsPresets)
                            if (preset.tag == tag) _presetChip(context, preset),
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _presetChip(BuildContext context, DnsPreset preset) {
    final alreadyAdded = _items.contains(preset.address);
    final l10n = AppLocalizations.of(context);

    return Tooltip(
      message: alreadyAdded
          ? (l10n?.dnsPresetAdded ?? 'Already in the list')
          : preset.address,
      child: FilterChip(
        selected: alreadyAdded,
        showCheckmark: false,
        avatar: alreadyAdded
            ? Icon(
                Icons.check,
                size: 16,
                color: Theme.of(context).colorScheme.primary,
              )
            : null,
        label: Text('${preset.label} · ${preset.kind.badge}'),
        onSelected: alreadyAdded ? null : (_) => _addItems([preset.address]),
      ),
    );
  }

  void _onFieldChanged(String value) {
    final unrecognised =
        value.trim().isNotEmpty &&
        classifyUpstream(value) == DnsUpstreamKind.unknown;
    if (unrecognised != _unrecognisedEntry) {
      setState(() => _unrecognisedEntry = unrecognised);
    }
  }

  void _addFromField() {
    final value = _controller.text.trim();
    if (value.isEmpty) return;
    _addItems([value]);
    _controller.clear();
    _onFieldChanged('');
  }

  void _addItems(List<String> addresses) {
    final additions = addresses
        .where((address) => !_items.contains(address))
        .toList();
    if (additions.isEmpty) return;

    widget.onAdd(additions);
    setState(() => _items.addAll(additions));
  }

  void _removeItem(String item) {
    widget.onRemove(item);
    setState(() => _items.remove(item));
  }
}
