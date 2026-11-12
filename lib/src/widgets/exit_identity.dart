import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/exit_ip_service.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_shapes.dart';
import '../theme/app_motion.dart';

/// The same compact identity block fits a phone hero or a desktop status card.
class ExitIdentity extends StatelessWidget {
  const ExitIdentity({
    super.key,
    required this.report,
    required this.loading,
    required this.failed,
    required this.onRefresh,
  });
  final ExitIpReport? report;
  final bool loading;
  final bool failed;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final l10n =
        AppLocalizations.of(context) ??
        AppLocalizations(Localizations.localeOf(context));
    final c = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final value = report;
    final network = switch (value?.network ?? IpNetworkKind.unknown) {
      IpNetworkKind.residentialCandidate => l10n.exitResidential,
      IpNetworkKind.mobile => l10n.exitMobile,
      IpNetworkKind.hosting => l10n.exitHosting,
      IpNetworkKind.proxy => l10n.exitProxy,
      IpNetworkKind.unknown => l10n.exitUnknown,
    };
    final score = value?.riskScore;
    final risk = score == null
        ? l10n.exitUnrated
        : score <= 10
        ? l10n.exitLowRisk
        : l10n.exitRiskScore(score);
    final detail = value == null
        ? l10n.exitRefresh
        : '${value.source} · ${TimeOfDay.fromDateTime(value.checkedAt).format(context)}\n${l10n.exitAssessment}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onLongPress: value == null
              ? null
              : () => Clipboard.setData(ClipboardData(text: value.ip)),
          child: AnimatedSwitcher(
            duration: AppMotion.duration(context, AppMotion.short),
            switchInCurve: AppMotion.standardCurve,
            switchOutCurve: AppMotion.standardCurve,
            child: Text(
              value?.ip ?? (loading ? l10n.exitChecking : '—'),
              key: ValueKey(value?.ip ?? (loading ? 'loading' : 'empty')),
              style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final label in [network, risk])
              Tooltip(
                message: detail,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: label == risk && score != null
                        ? score > 50
                              ? c.errorContainer
                              : c.secondaryContainer
                        : c.surfaceContainerHighest,
                    borderRadius: AppShapes.medium,
                  ),
                  child: Text(
                    label,
                    style: t.labelMedium?.copyWith(
                      color: label == risk && score != null
                          ? score > 50
                                ? c.onErrorContainer
                                : c.onSecondaryContainer
                          : c.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          value?.organization ??
              (failed ? l10n.exitUnavailable : l10n.exitProvider),
          style: t.bodySmall,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Tooltip(
          message: detail,
          child: TextButton.icon(
            onPressed: loading ? null : onRefresh,
            icon: Icon(
              loading ? Icons.more_horiz : Icons.refresh_rounded,
              size: 16,
            ),
            label: Text(value?.source ?? l10n.exitRefresh),
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              minimumSize: const Size(48, 48),
            ),
          ),
        ),
      ],
    );
  }
}
