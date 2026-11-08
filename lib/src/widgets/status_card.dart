import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/utils/responsive_utils.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/theme/app_motion.dart';
import 'package:arcadiaplus/src/widgets/adaptive_button.dart';

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
    final description = isRunning
        ? (l10n?.arcadiaplusRunning ?? 'ArcadiaPlus is running')
        : (l10n?.serviceNotRunning ?? 'Service not running');
    final foreground = isRunning ? colors.onPrimaryContainer : colors.onSurface;
    final duration = AppMotion.duration(context);

    return AnimatedContainer(
      duration: duration,
      curve: AppMotion.curve,
      decoration: BoxDecoration(
        color: isRunning ? colors.primaryContainer : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ExcludeSemantics(
                child: AnimatedContainer(
                  duration: duration,
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: isRunning
                        ? colors.primary
                        : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    isRunning
                        ? Icons.check_rounded
                        : Icons.power_settings_new_rounded,
                    color: isRunning
                        ? colors.onPrimary
                        : colors.onSurfaceVariant,
                    size: 26,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  l10n?.serviceStatus ?? 'Service Status',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: foreground,
                  ),
                ),
              ),
              if (isLoading) ...[
                const SizedBox(width: 12),
                SizedBox.square(
                  dimension: 22,
                  child: MediaQuery.disableAnimationsOf(context)
                      ? Icon(
                          Icons.hourglass_top_rounded,
                          size: 22,
                          color: foreground,
                        )
                      : CircularProgressIndicator(
                          strokeWidth: 2,
                          color: foreground,
                        ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 24),
          Semantics(
            liveRegion: true,
            label: status,
            excludeSemantics: true,
            child: AnimatedSwitcher(
              duration: duration,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (current, previous) => Stack(
                alignment: AlignmentDirectional.centerStart,
                children: [...previous, ?current],
              ),
              child: Text(
                status,
                key: ValueKey(status),
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: AdaptiveButton(
              onPressed: isLoading
                  ? null
                  : () {
                      AnimationUtils.mediumHaptic();
                      onStartStop();
                    },
              style: FilledButton.styleFrom(
                minimumSize: const Size(48, 52),
                backgroundColor: isRunning ? colors.surface : colors.primary,
                foregroundColor: isRunning
                    ? colors.onSurface
                    : colors.onPrimary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 16,
                ),
              ),
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
