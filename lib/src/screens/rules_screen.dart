import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/providers/app_state_provider.dart';
import 'package:arcadiaplus/src/rust/api.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/services/rule_provider_service.dart';
import 'package:arcadiaplus/src/utils/responsive_utils.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

/// The rule table as the engine sees it: every configured rule with its live
/// hit count, the conversion warnings that explain anything that did not make
/// it into the table, and the state of the rule sets backing `RULE-SET`.
///
/// The hit counts are what make this screen diagnostic rather than decorative:
/// a rule that never fires, or one that fires for everything, is visible here
/// instead of being guessed at from the traffic that goes the wrong way.
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  List<RuleDto>? _rules;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rules = await getRules();
      if (!mounted) return;
      setState(() {
        _rules = rules;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final spacing = ResponsiveUtils.getSpacing(context);
    final radius = ResponsiveUtils.getBorderRadius(context);

    final appState = context.watch<AppStateProvider>();
    final warnings = appState.configWarnings;
    final report = appState.ruleSetReport;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n?.rulesTitle ?? 'Rules'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/settings'),
        ),
        actions: [
          IconButton(
            tooltip: l10n?.rulesOpen ?? 'Rule diagnostics',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: ResponsiveUtils.getCardPadding(context),
          children: [
            Text(
              l10n?.rulesSubtitle ?? 'Evaluated top to bottom; the first match decides the outbound',
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            SizedBox(height: spacing * 1.5),
            _summaryRow(context, report),
            SizedBox(height: spacing * 1.5),
            _warningCard(context, warnings),
            SizedBox(height: spacing * 1.5),
            _ruleSetCard(context, report, radius),
            SizedBox(height: spacing * 1.5),
            _ruleList(context, radius),
            SizedBox(height: spacing * 2),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(BuildContext context, RuleProviderReport report) {
    final l10n = AppLocalizations.of(context);
    final rules = _rules;
    final totalHits = rules?.fold<BigInt>(
      BigInt.zero,
      (sum, rule) => sum + rule.matchedCount,
    );
    final failed = report.failed.length;

    return Row(
      children: [
        Expanded(
          child: _summaryTile(
            context,
            icon: Icons.list_alt_outlined,
            label: l10n?.rulesSummaryRules ?? 'Rules',
            value: _error != null
                ? '—'
                : (rules?.length.toString() ?? (l10n?.rulesNever ?? 'never')),
          ),
        ),
        SizedBox(width: ResponsiveUtils.getSpacing(context)),
        Expanded(
          child: _summaryTile(
            context,
            icon: Icons.bolt_outlined,
            label: l10n?.rulesSummaryHits ?? 'Matches',
            value: totalHits?.toString() ?? '—',
          ),
        ),
        SizedBox(width: ResponsiveUtils.getSpacing(context)),
        Expanded(
          child: _summaryTile(
            context,
            icon: Icons.folder_open_outlined,
            label: l10n?.rulesSummaryRuleSets ?? 'Rule sets',
            value: report.states.isEmpty
                ? '0'
                : '${report.states.length - failed}/${report.states.length}',
            accent: failed > 0,
          ),
        ),
      ],
    );
  }

  Widget _summaryTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    bool accent = false,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final radius = ResponsiveUtils.getBorderRadius(context);

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: accent
          ? colorScheme.errorContainer
          : colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              icon,
              size: 18,
              color: accent
                  ? colorScheme.onErrorContainer
                  : colorScheme.primary,
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: textTheme.titleLarge?.copyWith(
                color: accent
                    ? colorScheme.onErrorContainer
                    : colorScheme.onSurface,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.labelMedium?.copyWith(
                color: accent
                    ? colorScheme.onErrorContainer
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _warningCard(BuildContext context, List<String> warnings) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final radius = ResponsiveUtils.getBorderRadius(context);

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  warnings.isEmpty
                      ? Icons.check_circle_outline
                      : Icons.warning_amber_rounded,
                  size: 20,
                  color: warnings.isEmpty
                      ? colorScheme.primary
                      : colorScheme.tertiary,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n?.rulesWarningsTitle ?? 'Conversion warnings',
                  style: textTheme.titleSmall,
                ),
                const Spacer(),
                Text(
                  warnings.length.toString(),
                  style: textTheme.labelLarge?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (warnings.isEmpty)
              Text(
                l10n?.rulesWarningsEmpty ?? 'Nothing was dropped or rewritten',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final warning in warnings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '• $warning',
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _ruleSetCard(
    BuildContext context,
    RuleProviderReport report,
    double radius,
  ) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.folder_open_outlined,
                  size: 20,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  l10n?.rulesSummaryRuleSets ?? 'Rule sets',
                  style: textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (report.states.isEmpty)
              Text(
                l10n?.rulesRuleSetsEmpty ??
                    'This profile declares no rule sets',
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (final state in report.states)
                _ruleSetRow(context, state, l10n),
          ],
        ),
      ),
    );
  }

  Widget _ruleSetRow(
    BuildContext context,
    RuleProviderState state,
    AppLocalizations? l10n,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final updated = state.updatedAt;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  state.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                state.ready ? Icons.check_circle_outline : Icons.error_outline,
                size: 16,
                color: state.ready ? colorScheme.primary : colorScheme.error,
              ),
              const SizedBox(width: 4),
              Text(
                state.ready
                    ? (l10n?.rulesReady ?? 'ready')
                    : (l10n?.rulesFailed ?? 'failed'),
                style: textTheme.labelSmall?.copyWith(
                  color: state.ready ? colorScheme.primary : colorScheme.error,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${l10n?.rulesBehavior ?? 'behavior'}: ${state.behavior} · '
            '${state.entries} ${l10n?.rulesEntries ?? 'entries'}'
            '${state.skipped > 0 ? ' · ${state.skipped} ${l10n?.rulesSkipped ?? 'skipped'}' : ''}'
            ' · ${l10n?.rulesUpdated ?? 'updated'}: '
            '${updated == null ? (l10n?.rulesNever ?? 'never') : _formatTime(updated)}',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                state.error!,
                style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _ruleList(BuildContext context, double radius) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (_loading && _rules == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: colorScheme.errorContainer,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n?.rulesEngineOff ??
                    'The engine is not running, so hit counts are unavailable',
                style: textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onErrorContainer,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _error!,
                style: textTheme.bodySmall?.copyWith(
                  color: colorScheme.onErrorContainer,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final rules = _rules ?? const <RuleDto>[];
    if (rules.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: Text(
            l10n?.rulesRulesEmpty ?? 'The engine has no rules loaded',
            style: textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Column(
        children: [
          for (var index = 0; index < rules.length; index++) ...[
            _ruleRow(context, rules[index], index),
            if (index != rules.length - 1)
              const Divider(height: 1, indent: 16, endIndent: 16),
          ],
        ],
      ),
    );
  }

  Widget _ruleRow(BuildContext context, RuleDto rule, int index) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final payload = rule.payload.isEmpty ? '—' : rule.payload;
    final hits = rule.matchedCount;

    return ListTile(
      dense: true,
      leading: SizedBox(
        width: 34,
        child: Text(
          '#${index + 1}',
          style: textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              rule.ruleType.toUpperCase(),
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSecondaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              payload,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.bodyMedium,
            ),
          ),
        ],
      ),
      subtitle: Text(
        '→ ${rule.outbound}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: Text(
        hits.toString(),
        style: textTheme.labelLarge?.copyWith(
          color: hits == BigInt.zero
              ? colorScheme.onSurfaceVariant
              : colorScheme.primary,
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
