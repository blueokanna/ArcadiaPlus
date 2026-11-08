import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:arcadiaplus/src/providers/proxies_provider.dart';
import 'package:arcadiaplus/src/services/config_converter.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/widgets/proxy_node_tile.dart';

class ProxiesScreen extends StatefulWidget {
  const ProxiesScreen({super.key});
  @override
  State<ProxiesScreen> createState() => _ProxiesScreenState();
}

class _ProxiesScreenState extends State<ProxiesScreen> {
  int _columns = 0;
  int _layoutRevision = 0;

  Future<void> _loadLayout() async {
    final revision = _layoutRevision;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt('proxy_node_columns') ?? 0;
      if (mounted && revision == _layoutRevision && saved >= 0 && saved <= 2) {
        setState(() => _columns = saved);
      }
    } catch (_) {
      // A missing preference does not prevent access to the node list.
    }
  }

  Future<void> _setColumns(int columns) async {
    final revision = ++_layoutRevision;
    setState(() => _columns = columns);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (revision != _layoutRevision) return;
      if (!await prefs.setInt('proxy_node_columns', columns)) {
        throw StateError('Could not save node layout');
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _loadLayout();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ProxiesProvider>().loadFromActiveProfile();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Latency arrivals belong to individual tiles; they do not rebuild the
    // page header, group selector or scroll layout.
    final state = context
        .select<ProxiesProvider, (ParsedClashConfig?, String?, bool, String?)>(
          (p) => (p.config, p.selectedGroupName, p.isLoading, p.error),
        );
    final provider = context.read<ProxiesProvider>();
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final group = provider.selectedGroup;
    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1200),
            child: CustomScrollView(
              key: const PageStorageKey('proxy-nodes'),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n?.proxies ?? 'Proxies',
                            style: text.headlineMedium,
                          ),
                        ),
                        MenuAnchor(
                          menuChildren: [
                            for (final value in [0, 1, 2])
                              MenuItemButton(
                                onPressed: () => _setColumns(value),
                                leadingIcon: _columns == value
                                    ? const Icon(Icons.check)
                                    : const SizedBox.square(dimension: 24),
                                child: Text(
                                  Localizations.localeOf(context)
                                              .languageCode ==
                                          'zh'
                                      ? [
                                          '\u81ea\u52a8',
                                          '\u4e00\u5217',
                                          '\u4e24\u5217',
                                        ][value]
                                      : [
                                          'Automatic',
                                          'One column',
                                          'Two columns',
                                        ][value],
                                ),
                              ),
                          ],
                          builder: (context, controller, _) => IconButton(
                            tooltip:
                                Localizations.localeOf(context).languageCode ==
                                    'zh'
                                ? '\u8282\u70b9\u5e03\u5c40'
                                : 'Node layout',
                            onPressed: () => controller.isOpen
                                ? controller.close()
                                : controller.open(),
                            icon: Icon(
                              _columns == 1
                                  ? Icons.view_list_rounded
                                  : Icons.grid_view_rounded,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: l10n?.refresh ?? 'Refresh',
                          onPressed: state.$3
                              ? null
                              : provider.loadFromActiveProfile,
                          icon: const Icon(Icons.refresh_rounded),
                        ),
                      ],
                    ),
                  ),
                ),
                if (state.$3)
                  const SliverToBoxAdapter(child: LinearProgressIndicator()),
                if (state.$4 != null)
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 8,
                    ),
                    sliver: SliverToBoxAdapter(
                      child: Card.filled(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            state.$4!,
                            style: text.bodyMedium?.copyWith(
                              color: Theme.of(context)
                                  .colorScheme
                                  .onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                if (provider.proxyGroups.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          for (final candidate in provider.proxyGroups)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                showCheckmark: false,
                                selected: candidate.name == group?.name,
                                label: Text(candidate.name),
                                avatar: Icon(
                                  _groupIcon(candidate.type),
                                  size: 18,
                                ),
                                onSelected: (_) =>
                                    provider.selectGroup(candidate.name),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (group != null) ...[
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
                      sliver: SliverToBoxAdapter(
                        child: Wrap(
                          spacing: 16,
                          runSpacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '${group.proxies.length} ${l10n?.nodes ?? 'nodes'}',
                              style: text.titleMedium,
                            ),
                            const _TestButton(),
                          ],
                        ),
                      ),
                    ),
                    _NodeGrid(group: group, preferredColumns: _columns),
                  ],
                ] else if (!state.$3)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.dns_outlined,
                            size: 48,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                          const SizedBox(height: 20),
                          Text(
                            l10n?.noProxies ?? 'No proxies available',
                            style: text.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            l10n?.noActiveProfile ??
                                'Select a profile to begin',
                            textAlign: TextAlign.center,
                            style: text.bodyMedium,
                          ),
                          const SizedBox(height: 24),
                          FilledButton.icon(
                            onPressed: () => context.go('/profiles'),
                            icon: const Icon(Icons.folder_open_rounded),
                            label: Text(l10n?.profiles ?? 'Profiles'),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 32)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _groupIcon(String type) => switch (type.toLowerCase()) {
  'url-test' => Icons.speed_rounded,
  'fallback' => Icons.swap_horiz_rounded,
  'load-balance' => Icons.balance_rounded,
  _ => Icons.layers_outlined,
};

class _TestButton extends StatelessWidget {
  const _TestButton();
  @override
  Widget build(BuildContext context) {
    final testing = context.select<ProxiesProvider, bool>((p) => p.isTesting);
    final l10n = AppLocalizations.of(context);
    return FilledButton.tonalIcon(
      onPressed: testing
          ? null
          : context.read<ProxiesProvider>().testAllLatencies,
      icon: testing && !MediaQuery.disableAnimationsOf(context)
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(testing ? Icons.hourglass_top_rounded : Icons.speed_rounded),
      label: Text(
        testing
            ? (l10n?.loading ?? 'Testing…')
            : (l10n?.latencyTest ?? 'Latency test'),
      ),
    );
  }
}

class _NodeGrid extends StatelessWidget {
  const _NodeGrid({required this.group, required this.preferredColumns});
  final int preferredColumns;
  final ParsedProxyGroup group;

  @override
  Widget build(BuildContext context) {
    final items = context.read<ProxiesProvider>().getProxiesForGroup(group);
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      sliver: SliverLayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final columns = preferredColumns == 0
              ? (constraints.crossAxisExtent / (270 * scale.clamp(1, 2)))
                    .floor()
                    .clamp(1, 4)
              : preferredColumns;
          Widget itemBuilder(BuildContext context, int index) {
            final item = items[index];
            final name = switch (item) {
              ParsedProxy p => p.name,
              ParsedProxyGroup g => g.name,
              _ => item.toString(),
            };
            return _NodeItem(
              key: ValueKey('${group.name}:$name'),
              group: group.name,
              item: item,
            );
          }

          if (columns == 1) {
            return SliverList.separated(
              itemCount: items.length,
              itemBuilder: itemBuilder,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
            );
          }
          return SliverGrid(
            delegate: SliverChildBuilderDelegate(
              itemBuilder,
              childCount: items.length,
            ),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              mainAxisExtent: 76 + 80 * scale.clamp(1, 3),
            ),
          );
        },
      ),
    );
  }
}

class _NodeItem extends StatelessWidget {
  const _NodeItem({super.key, required this.group, required this.item});
  final String group;
  final Object item;

  @override
  Widget build(BuildContext context) {
    final name = switch (item) {
      ParsedProxy p => p.name,
      ParsedProxyGroup g => g.name,
      _ => item.toString(),
    };
    final state = context.select<ProxiesProvider, (bool, bool, LatencyResult?)>(
      (p) => (
        p.getSelectedProxyForGroup(group) == name,
        p.isSelecting(group),
        p.getLatency(name),
      ),
    );
    final l10n = AppLocalizations.of(context);
    final latency = state.$3;
    final subtitle = switch (item) {
      ParsedProxy p => p.displayType,
      ParsedProxyGroup g => '${g.proxies.length} ${l10n?.nodes ?? 'nodes'}',
      'DIRECT' => l10n?.direct ?? 'Direct',
      'REJECT' => 'REJECT',
      _ => l10n?.failed ?? 'Unavailable',
    };
    final icon = switch (item) {
      ParsedProxyGroup() => Icons.layers_outlined,
      'DIRECT' => Icons.arrow_outward_rounded,
      'REJECT' => Icons.block_rounded,
      _ => Icons.public_rounded,
    };
    final available =
        item is ParsedProxy ||
        item is ParsedProxyGroup ||
        name == 'DIRECT' ||
        name == 'REJECT';
    return ProxyNodeTile(
      name: name,
      subtitle: subtitle,
      selected: state.$1,
      onPressed: state.$2 || !available
          ? null
          : () =>
                context.read<ProxiesProvider>().selectProxyInGroup(group, name),
      icon: icon,
      failed: latency != null && !latency.isSuccess,
      latency: item is! ParsedProxy
          ? null
          : latency == null
          ? l10n?.notTested ?? 'Not tested'
          : latency.isSuccess
          ? '${latency.latencyMs} ms'
          : l10n?.failed ?? 'Failed',
    );
  }
}
