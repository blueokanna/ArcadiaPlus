import 'package:arcadiaplus/src/widgets/connection_destination.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:arcadiaplus/src/providers/app_state_provider.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/utils/app_lifecycle.dart';
import 'package:arcadiaplus/src/utils/platform_utils.dart';
import 'package:arcadiaplus/src/utils/responsive_utils.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';
import 'package:arcadiaplus/src/theme/app_motion.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';

class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key});

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> with RouteAware {
  static const Duration _listInterval = Duration(seconds: 3);

  Timer? _listTimer;
  bool _onTop = true;
  bool _observingLifecycle = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
      _onTop = route.isCurrent;
    }
    if (!_observingLifecycle) {
      _observingLifecycle = true;
      AppLifecycle.instance.active.addListener(_syncTimer);
    }
    _syncTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppStateProvider>().refreshConnections();
    });
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    if (_observingLifecycle) {
      AppLifecycle.instance.active.removeListener(_syncTimer);
      _observingLifecycle = false;
    }
    _listTimer?.cancel();
    super.dispose();
  }

  void _setOnTop(bool onTop) {
    if (_onTop == onTop) return;
    _onTop = onTop;
    _syncTimer();
    if (onTop) {
      context.read<AppStateProvider>().refreshConnections();
    }
  }

  @override
  void didPush() => _setOnTop(true);

  @override
  void didPopNext() => _setOnTop(true);

  @override
  void didPushNext() => _setOnTop(false);

  @override
  void didPop() => _setOnTop(false);

  void _syncTimer() {
    if (_onTop && AppLifecycle.instance.isActive) {
      _listTimer ??= Timer.periodic(_listInterval, (_) {
        if (mounted) context.read<AppStateProvider>().refreshConnections();
      });
    } else {
      _listTimer?.cancel();
      _listTimer = null;
    }
  }

  Future<void> _refresh() async {
    final appState = context.read<AppStateProvider>();
    await appState.refreshStatus();
    await appState.refreshConnections();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n?.connections ?? 'Connections',
          style: textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          Consumer<AppStateProvider>(
            builder: (context, appState, child) {
              if (appState.activeConnections.isNotEmpty) {
                return TextButton.icon(
                  onPressed: () => _showCloseAllDialog(context),
                  icon: const Icon(Icons.close),
                  label: Text(l10n?.closeAll ?? 'Close All'),
                  style: TextButton.styleFrom(
                    foregroundColor: colorScheme.error,
                  ),
                );
              }
              return const SizedBox.shrink();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh_outlined),
            tooltip: l10n?.refresh ?? 'Refresh',
            onPressed: _refresh,
          ),
        ],
      ),
      body: Consumer<AppStateProvider>(
        builder: (context, appState, child) {
          if (!appState.isServiceRunning) {
            return _buildNotRunningView(context);
          }

          if (appState.activeConnections.isEmpty) {
            return _buildEmptyView(context);
          }

          return _buildConnectionsList(context, appState);
        },
      ),
    );
  }

  Widget _buildNotRunningView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);
    final spacing = ResponsiveUtils.getSpacing(context);
    final iconSize = ResponsiveUtils.getIconSize(context, large: true);

    return Center(
      child: Padding(
        padding: ResponsiveUtils.getResponsivePadding(context),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: EdgeInsets.all(spacing * 3),
              decoration: BoxDecoration(
                color: colorScheme.errorContainer.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.power_off_rounded,
                size: iconSize * 2,
                color: colorScheme.error,
              ),
            ),
            SizedBox(height: spacing * 3),
            Text(
              l10n?.serviceNotRunningTitle ?? 'Service Not Running',
              style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: spacing),
            Text(
              l10n?.startServiceToViewConnections2 ??
                  'Start the ArcadiaPlus service to view active connections',
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);
    final spacing = ResponsiveUtils.getSpacing(context);
    final iconSize = ResponsiveUtils.getIconSize(context, large: true);

    return Center(
      child: Padding(
        padding: ResponsiveUtils.getResponsivePadding(context),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: EdgeInsets.all(spacing * 3),
              decoration: BoxDecoration(
                color: colorScheme.primaryContainer.withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.link_off_rounded,
                size: iconSize * 2,
                color: colorScheme.primary,
              ),
            ),
            SizedBox(height: spacing * 3),
            Text(
              l10n?.noActiveConnectionsTitle ?? 'No active connections',
              style: textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: spacing),
            Text(
              l10n?.connectionsWillAppear2 ?? 'Active connections will appear here as data flows through the proxy.',
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionsList(
    BuildContext context,
    AppStateProvider appState,
  ) {
    final connections = appState.activeConnections;
    final padding = ResponsiveUtils.getResponsivePadding(context);
    final spacing = ResponsiveUtils.getSpacing(context);

    return RefreshIndicator(
      onRefresh: _refresh,
      child: CustomScrollView(
        physics: PlatformUtils.getScrollPhysics(context),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                padding.left,
                spacing,
                padding.right,
                spacing * 2,
              ),
              child: _buildStatsHeader(context, appState),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: padding.left),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final connection = connections[index];
                return StaggeredListItem(
                  index: index,
                  delay: const Duration(milliseconds: 30),
                  duration: AnimationUtils.durationMedium2,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: spacing * 1.5),
                    child: _buildConnectionCard(context, connection, appState),
                  ),
                );
              }, childCount: connections.length),
            ),
          ),
          SliverToBoxAdapter(child: SizedBox(height: spacing * 2)),
        ],
      ),
    );
  }

  Widget _buildStatsHeader(BuildContext context, AppStateProvider appState) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final borderRadius = ResponsiveUtils.getBorderRadius(context);
    final cardPadding = ResponsiveUtils.getCardPadding(context);

    return Container(
      padding: cardPadding,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer.withValues(alpha: 0.5),
            colorScheme.secondaryContainer.withValues(alpha: 0.3),
          ],
        ),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _buildStatItem(
              context,
              icon: Icons.link_rounded,
              label: l10n?.activeConnections ?? 'Active connections',
              value: appState.activeConnections.length.toString(),
              color: colorScheme.primary,
            ),
          ),
          Container(width: 1, height: 40, color: colorScheme.outlineVariant),
          Expanded(
            child: _buildStatItem(
              context,
              icon: Icons.arrow_upward_rounded,
              label: l10n?.totalUploadShort ?? 'Total Uploads',
              value: appState.getFormattedTraffic(appState.totalUploadBytes),
              color: colorScheme.tertiary,
            ),
          ),
          Container(width: 1, height: 40, color: colorScheme.outlineVariant),
          Expanded(
            child: _buildStatItem(
              context,
              icon: Icons.arrow_downward_rounded,
              label: l10n?.totalDownloadShort ?? 'Total Downloads',
              value: appState.getFormattedTraffic(appState.totalDownloadBytes),
              color: colorScheme.secondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;
    final iconSize = ResponsiveUtils.getIconSize(context);
    final spacing = ResponsiveUtils.getSpacing(context);

    return Column(
      children: [
        Icon(icon, size: iconSize * 0.9, color: color),
        SizedBox(height: spacing * 0.5),
        Text(
          value,
          style: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
        Text(
          label,
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildConnectionCard(
    BuildContext context,
    ActiveConnection connection,
    AppStateProvider appState,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final borderRadius = ResponsiveUtils.getBorderRadius(context);
    final cardPadding = ResponsiveUtils.getCardPadding(context);
    final spacing = ResponsiveUtils.getSpacing(context);

    Color protocolColor;
    switch (connection.protocol.toUpperCase()) {
      case 'HTTPS':
        protocolColor = Colors.green;
        break;
      case 'HTTP':
        protocolColor = Colors.orange;
        break;
      case 'SOCKS5':
        protocolColor = Colors.blue;
        break;
      default:
        protocolColor = colorScheme.primary;
    }

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(borderRadius),
        onTap: () => _showConnectionDetails(context, connection),
        child: Padding(
          padding: cardPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: protocolColor,
                      boxShadow: [
                        BoxShadow(
                          color: protocolColor.withValues(alpha: 0.5),
                          blurRadius: 6,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: spacing * 1.5),
                  Expanded(
                    child: ConnectionDestination(
                      host: connection.host,
                      port: connection.destinationPort,
                      ip: connection.destinationIp,
                    ),
                  ),
                  _buildTrafficBadge(context, connection, appState),
                  SizedBox(width: spacing),
                  IconButton(
                    icon: Icon(
                      Icons.close_rounded,
                      color: colorScheme.error,
                      size: 20,
                    ),
                    onPressed: () => _closeConnection(context, connection),
                    tooltip: 'Close Connection',
                    visualDensity: VisualDensity.compact,
                    style: IconButton.styleFrom(
                      backgroundColor: colorScheme.errorContainer.withValues(
                        alpha: 0.3,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: spacing * 1.5),
              Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  _buildInfoChip(
                    context,
                    icon: Icons.rule_rounded,
                    label: connection.rule,
                    color: colorScheme.tertiary,
                  ),
                  _buildInfoChip(
                    context,
                    icon: Icons.security_rounded,
                    label: '${connection.protocol}/${connection.network}',
                    color: protocolColor,
                  ),
                  if (connection.outboundTag.isNotEmpty)
                    _buildInfoChip(
                      context,
                      icon: Icons.output_rounded,
                      label: connection.outboundTag,
                      color: colorScheme.secondary,
                    ),
                ],
              ),
              if (connection.rulePayload.isNotEmpty) ...[
                SizedBox(height: spacing),
                Text(
                  connection.rulePayload,
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrafficBadge(
    BuildContext context,
    ActiveConnection connection,
    AppStateProvider appState,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final borderRadius = ResponsiveUtils.getBorderRadius(context);
    final spacing = ResponsiveUtils.getSpacing(context);

    final uploadStr = _formatTrafficCompact(connection.uploadBytes);
    final downloadStr = _formatTrafficCompact(connection.downloadBytes);

    return AnimatedContainer(
      duration: AppMotion.duration(context),
      curve: AnimationUtils.curveStandard,
      padding: EdgeInsets.symmetric(
        horizontal: spacing * 1.25,
        vertical: spacing * 0.75,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(borderRadius * 0.75),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.arrow_upward_rounded,
            size: 12,
            color: colorScheme.tertiary,
          ),
          const SizedBox(width: 4),
          Text(
            uploadStr,
            style: textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.tertiary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          SizedBox(width: spacing),
          Icon(
            Icons.arrow_downward_rounded,
            size: 12,
            color: colorScheme.primary,
          ),
          const SizedBox(width: 4),
          Text(
            downloadStr,
            style: textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTrafficCompact(BigInt bytes) {
    final value = bytes.toDouble();
    if (value < 1024) {
      return '${value.toStringAsFixed(0)} B';
    } else if (value < 1024 * 1024) {
      return '${(value / 1024).toStringAsFixed(1)} KB';
    } else if (value < 1024 * 1024 * 1024) {
      return '${(value / 1024 / 1024).toStringAsFixed(2)} MB';
    } else {
      return '${(value / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
  }

  Widget _buildInfoChip(
    BuildContext context, {
    required IconData icon,
    required String label,
    required Color color,
  }) {
    final textTheme = Theme.of(context).textTheme;
    final spacing = ResponsiveUtils.getSpacing(context);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: spacing * 1.25,
        vertical: spacing * 0.75,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          SizedBox(width: spacing * 0.5),
          Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  void _closeConnection(BuildContext context, ActiveConnection connection) {
    context.read<AppStateProvider>().closeActiveConnectionById(connection.id);
  }

  void _showCloseAllDialog(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.warning_rounded, color: colorScheme.error, size: 48),
        title: const Text('Close All Connections'),
        content: const Text(
          'Are you sure you want to close all active connections? This may interrupt ongoing downloads or streaming.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              context.read<AppStateProvider>().closeAllActiveConnections();
              Navigator.of(context).pop();
            },
            style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
            child: const Text('Close All'),
          ),
        ],
      ),
    );
  }

  void _showConnectionDetails(
    BuildContext context,
    ActiveConnection connection,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final appState = context.read<AppStateProvider>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 16, 0),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.info_outline_rounded,
                      color: colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '连接详情',
                          style: textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          connection.host,
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 24),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                children: [
                  _buildDetailSection(
                    context,
                    title: 'Basic Information',
                    items: [
                      _DetailItem('Host', connection.host),
                      _DetailItem(
                        'Port',
                        connection.destinationPort.toString(),
                      ),
                      _DetailItem(
                        'Protocol',
                        '${connection.protocol}/${connection.network}',
                      ),
                      if (connection.destinationIp != null &&
                          connection.destinationIp!.isNotEmpty)
                        _DetailItem('Target IP', connection.destinationIp!),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _buildDetailSection(
                    context,
                    title: 'Routing Information',
                    items: [
                      _DetailItem('Rules', connection.rule),
                      if (connection.rulePayload.isNotEmpty)
                        _DetailItem('Rule Payload', connection.rulePayload),
                      _DetailItem('Inbound', connection.inboundTag),
                      _DetailItem('Outbound', connection.outboundTag),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _buildDetailSection(
                    context,
                    title: 'Traffic Statistics',
                    items: [
                      _DetailItem(
                        'Upload',
                        appState.getFormattedTraffic(connection.uploadBytes),
                      ),
                      _DetailItem(
                        'Download',
                        appState.getFormattedTraffic(connection.downloadBytes),
                      ),
                      _DetailItem(
                        'Creation Time',
                        _formatTimestamp(connection.startTime),
                      ),
                    ],
                  ),
                  if (connection.processName != null &&
                      connection.processName!.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _buildDetailSection(
                      context,
                      title: 'Process Information',
                      items: [
                        _DetailItem('Process Name', connection.processName!),
                      ],
                    ),
                  ],
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            Clipboard.setData(
                              ClipboardData(
                                text:
                                    '${connection.host}:${connection.destinationPort}',
                              ),
                            );
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Copied to clipboard'),
                              ),
                            );
                          },
                          icon: const Icon(Icons.copy_rounded),
                          label: const Text('Copy Address'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () {
                            appState.closeActiveConnectionById(connection.id);
                            Navigator.of(context).pop();
                          },
                          icon: const Icon(Icons.close_rounded),
                          label: const Text('Close Connection'),
                          style: FilledButton.styleFrom(
                            backgroundColor: colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailSection(
    BuildContext context, {
    required String title,
    required List<_DetailItem> items,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: textTheme.titleSmall?.copyWith(
            color: colorScheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: items.asMap().entries.map((entry) {
              final index = entry.key;
              final item = entry.value;
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 14,
                    ),
                    child: Row(
                      children: [
                        Text(
                          item.label,
                          style: textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const Spacer(),
                        Flexible(
                          child: Text(
                            item.value,
                            style: textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                            textAlign: TextAlign.end,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (index < items.length - 1)
                    Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: colorScheme.outlineVariant,
                    ),
                ],
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  String _formatTimestamp(BigInt timestamp) {
    final date = DateTime.fromMillisecondsSinceEpoch(timestamp.toInt());
    final now = DateTime.now();
    final diff = now.difference(date);

    if (diff.inSeconds < 60) {
      return '${diff.inSeconds} seconds ago';
    } else if (diff.inMinutes < 60) {
      return '${diff.inMinutes} minutes ago';
    } else if (diff.inHours < 24) {
      return '${diff.inHours} hours ago';
    } else {
      return '${date.month}/${date.day} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
    }
  }
}

class _DetailItem {
  final String label;
  final String value;

  _DetailItem(this.label, this.value);
}
