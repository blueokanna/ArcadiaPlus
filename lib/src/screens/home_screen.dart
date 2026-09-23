import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:arcadiaplus/src/providers/app_state_provider.dart';
import 'package:arcadiaplus/src/providers/general_settings_provider.dart';
import 'package:arcadiaplus/src/providers/theme_provider.dart';
import 'package:arcadiaplus/src/widgets/traffic_chart.dart';
import 'package:arcadiaplus/src/widgets/status_card.dart';
import 'package:arcadiaplus/src/widgets/quick_actions.dart';
import 'package:arcadiaplus/src/widgets/adaptive_list_tile.dart';
import 'package:arcadiaplus/src/utils/platform_utils.dart';
import 'package:arcadiaplus/src/utils/responsive_utils.dart';
import 'package:arcadiaplus/src/utils/device_info_utils.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';
import 'package:arcadiaplus/src/utils/app_lifecycle.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/rust/types.dart';

// Default traffic stats when service is not running
final _defaultTrafficStats = TrafficStats(
  upload: BigInt.zero,
  download: BigInt.zero,
  uploadSpeed: BigInt.zero,
  downloadSpeed: BigInt.zero,
);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RouteAware {
  /// Held so the claim can be released from `dispose`, where looking the
  /// provider up through the context is no longer safe.
  AppStateProvider? _appState;

  /// Whether this screen is the route on top. A route that is covered stays
  /// mounted and keeps rebuilding, so it must not also keep a poll alive.
  bool _onTop = true;

  /// Whether the live-stats claim is held right now, so it is taken and
  /// released exactly once.
  bool _claiming = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
      _onTop = route.isCurrent;
    }

    final appState = context.read<AppStateProvider>();
    if (!identical(appState, _appState)) {
      if (_claiming) {
        _appState?.releaseLiveStats();
        _claiming = false;
      }
      _appState = appState;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) appState.refreshStatus();
      });
    }

    _syncClaim();
  }

  /// Make the live-stats claim match "this screen is the one being looked at".
  void _syncClaim() {
    final appState = _appState;
    if (appState == null || _onTop == _claiming) return;
    _claiming = _onTop;
    if (_claiming) {
      appState.retainLiveStats();
    } else {
      appState.releaseLiveStats();
    }
  }

  void _setOnTop(bool onTop) {
    if (_onTop == onTop) return;
    _onTop = onTop;
    _syncClaim();
    if (onTop) {
      // Whatever is on screen is stale by however long this screen was
      // covered, so catch up once instead of waiting for the next tick.
      _appState?.refreshStatus();
    }
  }

  @override
  void didPush() => _setOnTop(true);

  /// The route above this one was popped: this screen is visible again.
  @override
  void didPopNext() => _setOnTop(true);

  /// Another route was pushed on top of this one.
  @override
  void didPushNext() => _setOnTop(false);

  @override
  void didPop() => _setOnTop(false);

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    if (_claiming) {
      _claiming = false;
      _appState?.releaseLiveStats();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'ArcadiaPlus',
          style: textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.palette_outlined),
            onPressed: () =>
                _showThemeSelector(context, context.read<ThemeProvider>()),
            tooltip: l10n?.changeTheme ?? 'Change theme',
          ),
          IconButton(
            icon: const Icon(Icons.refresh_outlined),
            onPressed: () => context.read<AppStateProvider>().refreshStatus(),
            tooltip: l10n?.refresh ?? 'Refresh',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await context.read<AppStateProvider>().refreshStatus();
        },
        child: SingleChildScrollView(
          physics: PlatformUtils.getScrollPhysics(context),
          padding: ResponsiveUtils.getResponsivePadding(context),
          child: SafeArea(
            top: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionHeader(
                  context,
                  l10n?.serviceStatus ?? 'Service Status',
                  Icons.power_settings_new_outlined,
                ),
                ResponsiveSpacing(multiplier: 1.5),
                const _StatusSection(),

                const _ServiceStatsSection(),

                ResponsiveSpacing(multiplier: 3),

                _sectionHeader(
                  context,
                  l10n?.trafficStatistics ?? 'Traffic Statistics',
                  Icons.show_chart_outlined,
                ),
                ResponsiveSpacing(multiplier: 1.5),
                const _TrafficSection(),

                ResponsiveSpacing(multiplier: 3),

                _sectionHeader(
                  context,
                  l10n?.quickActions ?? 'Quick Actions',
                  Icons.bolt_outlined,
                ),
                ResponsiveSpacing(multiplier: 1.5),
                const QuickActions(),

                ResponsiveSpacing(multiplier: 3),

                const _SystemInfoSection(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _systemInfoCard(
  BuildContext context,
  SystemInfo info,
  AppLocalizations? l10n,
) {
  final colorScheme = Theme.of(context).colorScheme;
  final borderRadius = ResponsiveUtils.getBorderRadius(context);

  // Format CPU info
  final cpuInfo = info.cpuName.isNotEmpty && !info.cpuName.contains('Unknown')
      ? '${info.cpuName} (${info.cpuCores}C/${info.cpuThreads}T)'
      : '${info.cpuCores} ${l10n?.cpuCores ?? "cores"} / ${info.cpuThreads} ${l10n?.cpuThreads ?? "threads"}';

  // Check if mobile platform (Android/iOS/HarmonyOS)
  final isMobile = PlatformUtils.isMobile;

  return Card(
    elevation: 0,
    color: colorScheme.surfaceContainerLow,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(borderRadius),
    ),
    child: Padding(
      padding: ResponsiveUtils.getCardPadding(context),
      child: Column(
        children: [
          _infoRow(
            context,
            icon: Icons.computer_outlined,
            label: l10n?.platform ?? 'Platform',
            value: info.platform,
          ),
          const Divider(height: 24),
          _infoRow(
            context,
            icon: Icons.phone_android_outlined,
            label: l10n?.deviceModel ?? 'Device Model',
            value: _deviceModel(),
          ),
          const Divider(height: 24),
          _infoRow(
            context,
            icon: Icons.memory_outlined,
            label: l10n?.memory ?? 'Memory',
            value:
                '${info.memoryUsed ~/ BigInt.from(1024) ~/ BigInt.from(1024)} MB',
          ),
          if (!isMobile) ...[
            const Divider(height: 24),
            _infoRow(
              context,
              icon: Icons.developer_board_outlined,
              label: l10n?.cpuCores ?? 'CPU',
              value: cpuInfo,
              scrollable: true,
            ),
          ],
        ],
      ),
    ),
  );
}

Widget _infoRow(
  BuildContext context, {
  required IconData icon,
  required String label,
  required String value,
  bool scrollable = false,
}) {
  final colorScheme = Theme.of(context).colorScheme;
  final textTheme = Theme.of(context).textTheme;
  final iconSize = ResponsiveUtils.getIconSize(context);
  final spacing = ResponsiveUtils.getSpacing(context);

  return Row(
    children: [
      Icon(icon, size: iconSize * 0.85, color: colorScheme.primary),
      SizedBox(width: spacing),
      Flexible(
        flex: 0,
        child: Text(
          label,
          style: textTheme.bodyMedium?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      SizedBox(width: spacing),
      Expanded(
        child: scrollable
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                child: Text(
                  value,
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.end,
                ),
              )
            : Align(
                alignment: Alignment.centerRight,
                child: Text(
                  value,
                  style: textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
      ),
    ],
  );
}

String _deviceModel() {
  if (Platform.isAndroid) {
    return DeviceInfoUtils.model;
  } else if (Platform.isWindows) {
    return 'Windows PC';
  } else if (Platform.isMacOS) {
    return 'Mac';
  } else if (Platform.isLinux) {
    return 'Linux PC';
  }
  return 'Unknown Device';
}

void _showThemeSelector(BuildContext context, ThemeProvider themeProvider) {
  final l10n = AppLocalizations.of(context);

  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.8,
      expand: false,
      builder: (context, scrollController) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n?.chooseTheme ?? 'Choose Theme',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: ListView(
                controller: scrollController,
                children: [
                  ...themeProvider.availableThemes.map((themeName) {
                    final isSelected = themeProvider.selectedTheme == themeName;
                    return AdaptiveListTile(
                      title: Text(themeProvider.getThemeDisplayName(themeName)),
                      leading: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _getThemeColor(themeName, context),
                        ),
                      ),
                      trailing: isSelected
                          ? Icon(
                              Icons.check,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      onTap: () {
                        themeProvider.setTheme(themeName);
                        Navigator.of(context).pop();
                      },
                      selected: isSelected,
                    );
                  }),
                  const Divider(),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.auto_awesome_outlined),
                      const SizedBox(width: 12),
                      Text(
                        l10n?.dynamicColors ?? 'Dynamic Colors',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const Spacer(),
                      Switch(
                        value: themeProvider.useDynamicColors,
                        onChanged: (value) =>
                            themeProvider.setUseDynamicColors(value),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Color _getThemeColor(String themeName, BuildContext context) {
  return context.read<ThemeProvider>().getThemeSeedColor(themeName);
}

Widget _sectionHeader(BuildContext context, String title, IconData icon) {
  final colorScheme = Theme.of(context).colorScheme;
  final textTheme = Theme.of(context).textTheme;
  final iconSize = ResponsiveUtils.getIconSize(context);

  return Row(
    children: [
      Icon(icon, size: iconSize * 0.9, color: colorScheme.primary),
      SizedBox(width: ResponsiveUtils.getSpacing(context)),
      Flexible(
        child: Text(
          title,
          style: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: colorScheme.primary,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}

/// 服务状态卡片。只在运行状态、加载状态或引擎状态快照变化时重建。
class _StatusSection extends StatelessWidget {
  const _StatusSection();

  @override
  Widget build(BuildContext context) {
    return Selector<
      AppStateProvider,
      ({bool isRunning, bool isLoading, ProxyStatus? status})
    >(
      selector: (_, appState) => (
        isRunning: appState.isServiceRunning,
        isLoading: appState.isLoading,
        status: appState.proxyStatus,
      ),
      builder: (context, snapshot, _) => StatusCard(
        isRunning: snapshot.isRunning,
        isLoading: snapshot.isLoading,
        proxyStatus: snapshot.status,
        onStartStop: () {
          final appState = context.read<AppStateProvider>();
          if (appState.isServiceRunning) {
            appState.stopService();
          } else {
            appState.startService();
          }
        },
      ),
    );
  }
}

/// 服务详细统计（仅运行时显示）。
class _ServiceStatsSection extends StatelessWidget {
  const _ServiceStatsSection();

  @override
  Widget build(BuildContext context) {
    return Selector<AppStateProvider, ProxyStatus?>(
      selector: (_, appState) =>
          appState.isServiceRunning ? appState.proxyStatus : null,
      builder: (context, status, _) => AnimatedSize(
        duration: AnimationUtils.stateChangeDuration,
        curve: AnimationUtils.curveEmphasized,
        child: status == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: 12),
                child: ServiceStatsCard(proxyStatus: status),
              ),
      ),
    );
  }
}

/// 流量统计。
///
/// 订阅范围刻意收窄到图表真正消费的四个值，并用 [RepaintBoundary] 把图表
/// 的绘制与整屏隔离：1 Hz 的速度更新只重绘这张图，而不是整页。
class _TrafficSection extends StatelessWidget {
  const _TrafficSection();

  @override
  Widget build(BuildContext context) {
    final proxyPort = context.watch<GeneralSettingsProvider>().mixedPort;

    return Selector<
      AppStateProvider,
      ({
        TrafficStats traffic,
        BigInt downloadSpeed,
        BigInt uploadSpeed,
        bool isRunning,
      })
    >(
      selector: (_, appState) => (
        traffic: appState.trafficStats ?? _defaultTrafficStats,
        downloadSpeed: appState.currentDownloadSpeed,
        uploadSpeed: appState.currentUploadSpeed,
        isRunning: appState.isServiceRunning,
      ),
      builder: (context, snapshot, _) => RepaintBoundary(
        child: TrafficChart(
          trafficStats: snapshot.traffic,
          downloadSpeed: snapshot.downloadSpeed,
          uploadSpeed: snapshot.uploadSpeed,
          isProxyRunning: snapshot.isRunning,
          proxyPort: proxyPort,
        ),
      ),
    );
  }
}

/// 系统信息。系统信息刷新很慢，所以这一块基本不会引起重建。
class _SystemInfoSection extends StatelessWidget {
  const _SystemInfoSection();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Selector<AppStateProvider, SystemInfo?>(
      selector: (_, appState) => appState.systemInfo,
      builder: (context, systemInfo, _) {
        if (systemInfo == null) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(
              context,
              l10n?.systemInformation ?? 'System Information',
              Icons.info_outline,
            ),
            ResponsiveSpacing(multiplier: 1.5),
            _systemInfoCard(context, systemInfo, l10n),
            ResponsiveSpacing(multiplier: 2),
          ],
        );
      },
    );
  }
}
