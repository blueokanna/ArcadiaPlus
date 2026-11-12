import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/utils/responsive_utils.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/theme/app_motion.dart';
import 'package:arcadiaplus/src/theme/app_shapes.dart';

import 'expressive_status_shape.dart';

/// One compact, accessible action; the shape is the control, not decoration.
class StatusCard extends StatelessWidget {
  const StatusCard({
    super.key,
    required this.isRunning,
    required this.isLoading,
    required this.onStartStop,
    this.identity,
    this.error,
    this.errorAction,
  });
  final bool isRunning;
  final bool isLoading;
  final VoidCallback onStartStop;
  final Widget? identity;
  final String? error;
  final Widget? errorAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final status = isLoading
        ? (isRunning
              ? (l10n?.stopping ?? 'Stopping...')
              : (l10n?.starting ?? 'Starting...'))
        : (isRunning
              ? (l10n?.running ?? 'Running')
              : (l10n?.stopped ?? 'Stopped'));
    final action = isLoading
        ? status
        : isRunning
        ? (l10n?.stopService ?? 'Stop Service')
        : (l10n?.startService ?? 'Start Service');
    return AnimatedContainer(
      duration: AppMotion.duration(context),
      curve: AppMotion.standardCurve,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.surfaceContainerLow,
        borderRadius: AppShapes.extraLarge,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                l10n?.serviceStatus ?? 'Service status',
                style: theme.textTheme.labelLarge,
              ),
              Semantics(
                liveRegion: true,
                child: AnimatedContainer(
                  duration: AppMotion.duration(context),
                  curve: AppMotion.standardCurve,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: ShapeDecoration(
                    color: isRunning
                        ? c.primaryContainer
                        : c.surfaceContainerHighest,
                    shape: const StadiumBorder(),
                  ),
                  child: Text(
                    status,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: isRunning
                          ? c.onPrimaryContainer
                          : c.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child:
                    identity ??
                    Text(status, style: theme.textTheme.headlineSmall),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 64,
                height: 64,
                child: ExpressiveStatusShape(
                  running: isRunning,
                  busy: isLoading,
                  child: Material(
                    color: c.primary,
                    child: IconButton(
                      key: const ValueKey('service-toggle'),
                      tooltip: action,
                      onPressed: isLoading
                          ? null
                          : () {
                              AnimationUtils.mediumHaptic();
                              onStartStop();
                            },
                      style: IconButton.styleFrom(
                        foregroundColor: c.onPrimary,
                        disabledForegroundColor: c.onPrimary.withValues(
                          alpha: .55,
                        ),
                        padding: EdgeInsets.zero,
                      ),
                      icon: AnimatedSwitcher(
                        duration: AppMotion.duration(context, AppMotion.short),
                        switchInCurve: AppMotion.standardCurve,
                        switchOutCurve: Curves.easeOut,
                        transitionBuilder: (child, animation) => FadeTransition(
                          opacity: animation,
                          child: ScaleTransition(
                            scale: Tween<double>(
                              begin: .8,
                              end: 1,
                            ).animate(animation),
                            child: child,
                          ),
                        ),
                        child: Icon(
                          isLoading
                              ? Icons.hourglass_top_rounded
                              : isRunning
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 28,
                          key: ValueKey((isRunning, isLoading)),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (error != null) ...[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: SelectableText(
                error!,
                style: theme.textTheme.bodyMedium?.copyWith(color: c.error),
              ),
            ),
            ?errorAction,
          ],
        ],
      ),
    );
  }
}

class ServiceStatsCard extends StatelessWidget {
  final ProxyStatus proxyStatus;

  const ServiceStatsCard({super.key, required this.proxyStatus});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final spacing = ResponsiveUtils.getSpacing(context);
    final borderRadius = ResponsiveUtils.getBorderRadius(context);

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing * 2),
        child: Row(
          children: [
            Expanded(
              child: _buildStatItem(
                context,
                Icons.link_rounded,
                l10n?.connections ?? 'Connections',
                proxyStatus.connectionCount.toString(),
                colorScheme.tertiary,
              ),
            ),
            _buildDivider(colorScheme),
            Expanded(
              child: _buildStatItem(
                context,
                Icons.timer_outlined,
                l10n?.uptime ?? 'Uptime',
                _formatUptime(proxyStatus.uptime),
                colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDivider(ColorScheme colorScheme) {
    return Container(
      width: 1,
      height: 40,
      color: colorScheme.outlineVariant.withValues(alpha: 0.3),
    );
  }

  Widget _buildStatItem(
    BuildContext context,
    IconData icon,
    String label,
    String value,
    Color color,
  ) {
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(height: 6),
        Text(
          value,
          style: textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  String _formatUptime(BigInt uptimeBigInt) {
    final seconds = uptimeBigInt.toInt();
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else if (minutes > 0) {
      return '${minutes}m';
    } else {
      return '${seconds}s';
    }
  }
}
