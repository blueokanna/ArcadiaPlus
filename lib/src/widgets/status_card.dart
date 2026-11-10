import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/utils/responsive_utils.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/theme/app_motion.dart';

import 'expressive_action.dart';
import 'expressive_status_shape.dart';

/// A stable control surface: only the state content changes, never the card's
/// scale. Running is a persistent state and does not require a repeating ticker.
class StatusCard extends StatelessWidget {
  const StatusCard({
    super.key,
    required this.isRunning,
    required this.isLoading,
    required this.onStartStop,
  });

  final bool isRunning;
  final bool isLoading;
  final VoidCallback onStartStop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final l10n = AppLocalizations.of(context);
    final status = isLoading
        ? (isRunning
              ? (l10n?.stopping ?? 'Stopping...')
              : (l10n?.starting ?? 'Starting...'))
        : (isRunning
              ? (l10n?.running ?? 'Running')
              : (l10n?.stopped ?? 'Stopped'));
    final foreground = isRunning ? colors.onPrimaryContainer : colors.onSurface;
    final duration = AppMotion.duration(context);

    final artwork = ExcludeSemantics(
      child: ExpressiveStatusShape(
        running: isRunning,
        child: AnimatedContainer(
          duration: duration,
          width: 64,
          height: 64,
          color: isRunning ? colors.primary : colors.surfaceContainerHighest,
          child: Icon(
            isRunning ? Icons.check_rounded : Icons.power_settings_new_rounded,
            color: isRunning ? colors.onPrimary : colors.onSurfaceVariant,
            size: 30,
          ),
        ),
      ),
    );
    final label = Text(
      l10n?.serviceStatus ?? 'Service status',
      style: theme.textTheme.labelMedium?.copyWith(color: foreground),
    );
    final state = Semantics(
      liveRegion: true,
      child: AnimatedDefaultTextStyle(
        duration: duration,
        style: theme.textTheme.headlineSmall!.copyWith(
          color: foreground,
          fontWeight: FontWeight.w700,
        ),
        child: Text(status, key: ValueKey(status)),
      ),
    );
    return AnimatedContainer(
      duration: duration,
      curve: AppMotion.curve,
      decoration: BoxDecoration(
        color: isRunning ? colors.primaryContainer : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(28),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 280 ||
                  MediaQuery.textScalerOf(context).scale(16) > 22) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: label),
                        const SizedBox(width: 12),
                        artwork,
                      ],
                    ),
                    const SizedBox(height: 8),
                    state,
                  ],
                );
              }
              return Row(
                children: [
                  artwork,
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [label, state],
                    ),
                  ),
                  if (isLoading && !MediaQuery.disableAnimationsOf(context))
                    const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          ExpressiveAction(
            selected: !isRunning,
            onPressed: isLoading
                ? null
                : () {
                    AnimationUtils.mediumHaptic();
                    onStartStop();
                  },
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isRunning ? Icons.stop_rounded : Icons.play_arrow_rounded,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    isLoading
                        ? status
                        : isRunning
                        ? (l10n?.stopService ?? 'Stop Service')
                        : (l10n?.startService ?? 'Start Service'),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
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
