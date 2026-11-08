import 'package:arcadiaplus/src/widgets/theme_picker.dart';

import 'dart:async';
import 'dart:io';

import 'package:arcadiaplus/src/theme/app_motion.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:arcadiaplus/src/providers/app_state_provider.dart';
import 'package:arcadiaplus/src/providers/general_settings_provider.dart';
import 'package:arcadiaplus/src/providers/network_settings_provider.dart';
import 'package:arcadiaplus/src/providers/theme_provider.dart';
import 'package:arcadiaplus/src/widgets/traffic_chart.dart';
import 'package:arcadiaplus/src/widgets/status_card.dart';
import 'package:arcadiaplus/src/widgets/quick_actions.dart';
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
      _appState?.refreshStatus();
      unawaited(context.read<NetworkSettingsProvider>().refresh());
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
                showThemePicker(context, context.read<ThemeProvider>()),
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
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1120),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final controls = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _StatusSection(),
                        const _ServiceStatsSection(),
                        const SizedBox(height: 28),
                        _sectionHeader(
                          context,
                          l10n?.quickActions ?? 'Quick Actions',
                          Icons.tune_rounded,
                        ),
                        const SizedBox(height: 16),
                        const QuickActions(),
                      ],
                    );
                    final traffic = Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _sectionHeader(
                          context,
                          l10n?.trafficStatistics ?? 'Traffic Statistics',
                          Icons.show_chart_rounded,
                        ),
                        const SizedBox(height: 16),
                        const _TrafficSection(),
                      ],
                    );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (constraints.maxWidth >= 960 &&
                            MediaQuery.textScalerOf(context).scale(14) <= 19)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 5, child: controls),
                              const SizedBox(width: 28),
                              Expanded(flex: 6, child: traffic),
                            ],
                          )
                        else ...[
                          controls,
                          const SizedBox(height: 28),
                          traffic,
                        ],
                        const SizedBox(height: 28),
                        const _SystemInfoSection(),
                      ],
                    );
                  },
                ),
              ),
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
  final cpuInfo = info.cpuName.isNotEmpty && !info.cpuName.contains('Unknown')
      ? '${info.cpuName} (${info.cpuCores}C/${info.cpuThreads}T)'
      : '${info.cpuCores} ${l10n?.cpuCores ?? "cores"} / ${info.cpuThreads} ${l10n?.cpuThreads ?? "threads"}';

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
            label: '${l10n?.memory ?? 'Memory'} (RSS)',
            value:
                '${info.memoryUsed ~/ BigInt.from(1024) ~/ BigInt.from(1024)} MiB',
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

Widget _sectionHeader(BuildContext context, String title, IconData icon) {
  final colorScheme = Theme.of(context).colorScheme;
  final textTheme = Theme.of(context).textTheme;
  final iconSize = ResponsiveUtils.getIconSize(context);

  return Row(
    children: [
      Icon(icon, size: iconSize * 0.9, color: colorScheme.onSurfaceVariant),
      SizedBox(width: ResponsiveUtils.getSpacing(context)),
      Flexible(
        child: Text(
          title,
          style: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: colorScheme.onSurface,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}

class _StatusSection extends StatelessWidget {
  const _StatusSection();

  @override
  Widget build(BuildContext context) {
    return Selector<AppStateProvider, ({bool isRunning, bool isLoading})>(
      selector: (_, appState) =>
          (isRunning: appState.isServiceRunning, isLoading: appState.isLoading),
      builder: (context, snapshot, _) => StatusCard(
        isRunning: snapshot.isRunning,
        isLoading: snapshot.isLoading,
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
        duration: AppMotion.duration(context),
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
