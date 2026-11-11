import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:arcadiaplus/src/widgets/routing_mode_selector.dart';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:arcadiaplus/src/services/platform_proxy_service.dart';
import 'package:arcadiaplus/src/providers/app_state_provider.dart';
import 'package:arcadiaplus/src/providers/network_settings_provider.dart';
import 'package:arcadiaplus/src/utils/responsive_utils.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';
import 'package:arcadiaplus/src/utils/platform_utils.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';

class QuickActions extends StatefulWidget {
  const QuickActions({super.key});

  @override
  State<QuickActions> createState() => _QuickActionsState();
}

class _QuickActionsState extends State<QuickActions> {
  bool _isProxyLoading = false;
  bool _isTunLoading = false;
  bool _isUpdating = false;

  @override
  void initState() {
    super.initState();
    // The switches mirror the platform, and the platform can have changed
    // while nothing was showing them. One read on appearance is enough: every
    // change made from inside the app arrives through the service's own
    // notifications.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<NetworkSettingsProvider>().refresh();
    });
  }

  Future<void> _toggleSystemProxy(
    bool enable,
    NetworkSettingsProvider networkSettings,
  ) async {
    if (_isProxyLoading || _isUpdating) return;

    if (Platform.isAndroid || PlatformUtils.isOHOS) {
      return;
    }

    setState(() {
      _isProxyLoading = true;
      _isUpdating = true;
    });

    try {
      await networkSettings.setSystemProxy(enable);
      AnimationUtils.mediumHaptic();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      _showSnackBar(
        enable
            ? (l10n?.systemProxyEnabled ?? 'System proxy enabled')
            : (l10n?.systemProxyDisabled ?? 'System proxy disabled'),
      );
    } catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      _showSnackBar(
        enable
            ? (l10n?.enableSystemProxyFailed ?? 'Failed to enable system proxy')
            : (l10n?.disableSystemProxyFailed ??
                  'Failed to disable system proxy'),
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isProxyLoading = false;
          _isUpdating = false;
        });
      }
    }
  }

  Future<void> _toggleTunMode(
    bool enable,
    NetworkSettingsProvider networkSettings,
  ) async {
    if (_isTunLoading || _isUpdating) return;

    setState(() {
      _isTunLoading = true;
      _isUpdating = true;
    });

    try {
      await networkSettings.setTunEnabled(enable);
      AnimationUtils.mediumHaptic();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      _showSnackBar(
        '${l10n?.tunMode ?? "TUN Mode"} ${enable ? (l10n?.enabled ?? "enabled") : (l10n?.disabled ?? "disabled")}',
      );
    } catch (e) {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      _showSnackBar(
        '${l10n?.failed ?? "Failed"}: ${l10n?.tunMode ?? "TUN Mode"}',
        isError: true,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isTunLoading = false;
          _isUpdating = false;
        });
      }
    }
  }

  Future<void> _switchProxyMode(ProxyMode mode) async {
    if (_isUpdating) return;
    final appState = context.read<AppStateProvider>();

    setState(() {
      _isUpdating = true;
    });

    try {
      final success = await appState.setProxyMode(mode);
      if (!mounted) return;
      if (!success) {
        final l10n = AppLocalizations.of(context);
        _showSnackBar(
          '${l10n?.failed ?? 'Failed'}: ${mode.name}',
          isError: true,
        );
        return;
      }
      AnimationUtils.selectionHaptic();
      final l10n = AppLocalizations.of(context);
      final modeText = switch (mode) {
        ProxyMode.global => l10n?.globalProxy ?? 'Global Proxy',
        ProxyMode.rule => l10n?.ruleMode ?? 'Rule Mode',
        ProxyMode.direct => l10n?.directModeName ?? 'Direct Mode',
      };
      _showSnackBar('${l10n?.switchedTo ?? "Switched to"} $modeText');
    } finally {
      if (mounted) {
        setState(() {
          _isUpdating = false;
        });
      }
    }
  }

  void _showSnackBar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final spacing = ResponsiveUtils.getSpacing(context);
    final isMobile =
        PlatformUtils.isOHOS ||
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    final state = context
        .select<
          AppStateProvider,
          ({ProxyMode mode, bool loading, bool running})
        >(
          (value) => (
            mode: value.proxyMode,
            loading: value.isLoading,
            running: value.isServiceRunning,
          ),
        );
    final network = context.watch<NetworkSettingsProvider>();
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RoutingModeSelector(
                  mode: state.mode,
                  mobile: isMobile,
                  onChanged: _isUpdating || state.loading
                      ? null
                      : _switchProxyMode,
                ),
                const SizedBox(height: 12),
                Text(switch (state.mode) {
                  ProxyMode.rule =>
                    l10n?.ruleModeDesc ??
                        'Route traffic using the active profile rules.',
                  ProxyMode.global =>
                    l10n?.globalModeDesc ??
                        'Route traffic through the selected proxy.',
                  ProxyMode.direct => l10n?.directModeName ?? 'Direct Mode',
                }, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (isMobile)
          _ServiceStatusCard(
            isRunning: state.running,
            isTunEnabled: network.tunEnabled,
            currentMode: state.mode,
          )
        else
          _buildDesktopLayout(colorScheme, spacing),
      ],
    );
  }

  Widget _buildDesktopLayout(ColorScheme colorScheme, double spacing) {
    final l10n = AppLocalizations.of(context);
    final networkSettings = context.watch<NetworkSettingsProvider>();
    final isServiceRunning = context.select<AppStateProvider, bool>(
      (state) => state.isServiceRunning,
    );

    // Both switches configure a route to the local mixed port, so with the
    // engine stopped they would only point this machine at a port nobody
    // listens on. Offering them anyway is how "the proxy is on" and "the
    // internet is gone" come together.
    final stoppedHint =
        l10n?.serviceNotRunning ?? 'ArcadiaPlus service is not running';
    final systemProxyCard = _ProxyCard(
      icon: Icons.language_rounded,
      title: l10n?.systemProxy ?? 'System Proxy',
      description: isServiceRunning || networkSettings.systemProxy
          ? (l10n?.setSystemHttpSocksProxy ?? 'Set system HTTP/SOCKS proxy')
          : stoppedHint,
      isEnabled: networkSettings.systemProxy,
      isLoading: _isProxyLoading,
      enabled: isServiceRunning,
      onToggle: (enable) => _toggleSystemProxy(enable, networkSettings),
    );
    final tunCard = _ProxyCard(
      icon: Icons.router_rounded,
      title: l10n?.tunMode ?? 'TUN Mode',
      description: isServiceRunning || networkSettings.tunEnabled
          ? (l10n?.tunModeDesc ?? 'Requires administrator privileges')
          : stoppedHint,
      isEnabled: networkSettings.tunEnabled,
      isLoading: _isTunLoading,
      enabled: isServiceRunning,
      onToggle: (enable) => _toggleTunMode(enable, networkSettings),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 620 ||
            MediaQuery.textScalerOf(context).scale(14) > 19) {
          return Column(
            children: [
              systemProxyCard,
              SizedBox(height: spacing * 1.5),
              tunCard,
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: systemProxyCard),
            SizedBox(width: spacing * 1.5),
            Expanded(child: tunCard),
          ],
        );
      },
    );
  }
}

class _ServiceStatusCard extends StatelessWidget {
  const _ServiceStatusCard({
    required this.isRunning,
    required this.isTunEnabled,
    required this.currentMode,
  });
  final bool isRunning;
  final bool isTunEnabled;
  final ProxyMode currentMode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = Theme.of(context).colorScheme;
    final active = isRunning && isTunEnabled;
    final mode = switch (currentMode) {
      ProxyMode.rule => l10n?.ruleMode ?? 'Rule Mode',
      ProxyMode.global => l10n?.globalProxy ?? 'Global Proxy',
      ProxyMode.direct => l10n?.directModeName ?? 'Direct Mode',
    };
    return Card(
      child: ListTile(
        leading: Icon(
          active ? Icons.vpn_lock_outlined : Icons.shield_outlined,
          color: active ? colors.primary : colors.onSurfaceVariant,
        ),
        title: Text(l10n?.vpnProxy ?? 'VPN Proxy'),
        subtitle: Text(active ? mode : (l10n?.disabled ?? 'Disabled')),
        trailing: active
            ? Icon(Icons.check_rounded, color: colors.primary)
            : null,
      ),
    );
  }
}

class _ProxyCard extends StatelessWidget {
  const _ProxyCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.isEnabled,
    required this.isLoading,
    required this.enabled,
    required this.onToggle,
  });
  final IconData icon;
  final String title;
  final String description;
  final bool isEnabled;
  final bool isLoading;
  final bool enabled;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final interactive = !isLoading && (enabled || isEnabled);
    final colors = Theme.of(context).colorScheme;
    return Card(
      child: LayoutBuilder(
        builder: (context, constraints) => SwitchListTile(
          value: isEnabled,
          onChanged: interactive ? onToggle : null,
          title: Text(title),
          subtitle: Text(description),
          secondary: constraints.maxWidth < 360
              ? null
              : isLoading
              ? SizedBox.square(
                  dimension: 24,
                  child: MediaQuery.disableAnimationsOf(context)
                      ? const Icon(Icons.hourglass_top_rounded)
                      : const CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  icon,
                  color: isEnabled ? colors.primary : colors.onSurfaceVariant,
                ),
          shape: Theme.of(context).cardTheme.shape,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 8,
          ),
        ),
      ),
    );
  }
}
