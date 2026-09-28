import 'dart:async';

import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/providers/app_state_provider.dart';
import 'package:arcadiaplus/src/rust/api.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/services/rule_provider_service.dart';
import 'package:arcadiaplus/src/theme/app_theme.dart';
import 'package:arcadiaplus/src/utils/app_lifecycle.dart';
import 'package:arcadiaplus/src/utils/navigation.dart';
import 'package:arcadiaplus/src/utils/responsive_utils.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

/// The rule table as the engine sees it: a page of configured rules with
/// their live hit counts, the conversion warnings that explain anything that
/// did not make it into the table, and the state of the rule sets backing
/// `RULE-SET`.
///
/// The hit counts are what make this screen diagnostic rather than decorative:
/// a rule that never fires, or one that fires for everything, is visible here
/// instead of being guessed at from the traffic that goes the wrong way.
///
/// It is a *paged* view on purpose. A profile can hold tens of thousands of
/// rules, and the old all-at-once load decoded every one of them on the UI
/// isolate while building a `ListTile` per row — a freeze that made the rest
/// of the app unusable, from the one screen that exists to diagnose problems.
/// The snapshot and the search live in the Rust bridge; this screen keeps the
/// rows it is showing plus a bounded tail for smooth scrolling, and reaches
/// the rest of the table through search.
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key});

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  /// Rows requested per window. Two screenfuls: enough that scrolling does
  /// not hit the loader at every frame, small enough that one message stays
  /// cheap to decode.
  static const int _pageSize = 200;

  /// Ceiling on the rows held in the list. Scrolling is not a way to load an
  /// arbitrarily large table into memory; the search box is how the rest is
  /// reached, and it scans on the Rust side.
  static const int _maxLoadedRows = 5000;

  /// How long a search waits for the keyboard to settle before it runs. The
  /// scan itself is cheap; the debounce is for the keystrokes.
  static const Duration _searchDebounceDelay = Duration(milliseconds: 300);

  /// How often the first page re-reads the engine while this screen is open.
  /// Hit counts move with traffic, the top of the table is what a reader
  /// watches, and re-reading only it keeps the cost bounded.
  static const Duration _topPageRefresh = Duration(seconds: 5);

  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  Timer? _topPageTimer;

  List<RuleDto> _rules = const [];
  int _total = 0;
  BigInt _totalMatches = BigInt.zero;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  String _query = '';
  List<RuleDto> _searchResults = const [];
  int _searchMatched = 0;
  bool _searchTruncated = false;
  bool _searching = false;
  bool _searchFailed = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadFirstPage(refresh: false);
    _topPageTimer = Timer.periodic(_topPageRefresh, (_) => _refreshTopPage());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _topPageTimer?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadFirstPage({required bool refresh}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final window = await getRulesWindow(
        offset: 0,
        limit: _pageSize,
        refresh: refresh,
      );
      if (!mounted) return;
      setState(() {
        _rules = window.rules;
        _total = window.total;
        _totalMatches = window.totalMatches;
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

  /// Re-reads the rows currently at the top of the table, quietly.
  ///
  /// Quiet because this runs on a timer: a page of the table has no loading
  /// state to show, and the refresh either replaces the top rows or leaves
  /// what is there. Failures are logged rather than surfaced — the next
  /// visible action (scrolling, refreshing, searching) reports them properly.
  Future<void> _refreshTopPage() async {
    if (!mounted || !AppLifecycle.instance.isActive) return;
    if (_query.isNotEmpty || _loading || _loadingMore || _error != null) return;
    try {
      final window = await getRulesWindow(
        offset: 0,
        limit: _pageSize,
        refresh: false,
      );
      if (!mounted || _query.isNotEmpty) return;
      setState(() {
        _total = window.total;
        _totalMatches = window.totalMatches;
        // Rows past the first page are somebody else's load and are kept; the
        // head of the list is replaced with the fresh copy.
        _rules = _rules.length <= window.rules.length
            ? window.rules
            : [...window.rules, ..._rules.sublist(window.rules.length)];
      });
    } catch (error) {
      debugPrint('Failed to refresh the rule table: $error');
    }
  }

  /// Appends the next page once the list is close to the end of what is
  /// loaded, up to [_maxLoadedRows].
  Future<void> _loadMore() async {
    if (_loadingMore || _loading || _query.isNotEmpty || _error != null) {
      return;
    }
    if (_rules.length >= _total || _rules.length >= _maxLoadedRows) return;

    _loadingMore = true;
    try {
      final window = await getRulesWindow(
        offset: _rules.length,
        limit: _pageSize,
        refresh: false,
      );
      if (!mounted) return;
      setState(() {
        // The table can shrink between windows (a reload), in which case the
        // offset comes back clamped; rows before it are kept and the tail is
        // replaced by what the engine reports from there on.
        final head = window.offset <= _rules.length
            ? _rules.sublist(0, window.offset)
            : _rules;
        _rules = [...head, ...window.rules];
        _total = window.total;
        _totalMatches = window.totalMatches;
      });
    } catch (error) {
      debugPrint('Failed to load more rules: $error');
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 600) {
      _loadMore();
    }
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_searchDebounceDelay, () => _runSearch(value));
  }

  Future<void> _runSearch(String value) async {
    final needle = value.trim();
    if (needle.isEmpty) {
      if (!mounted) return;
      setState(() {
        _query = '';
        _searchResults = const [];
        _searchMatched = 0;
        _searchTruncated = false;
        _searching = false;
        _searchFailed = false;
      });
      return;
    }

    setState(() {
      _query = needle;
      _searching = true;
      _searchFailed = false;
    });
    try {
      final result = await searchRules(needle: needle, limit: 500);
      if (!mounted || _query != needle) return;
      setState(() {
        _searchResults = result.rules;
        _searchMatched = result.matched;
        _searchTruncated = result.truncated;
        _searching = false;
        _searchFailed = false;
      });
    } catch (error) {
      if (!mounted || _query != needle) return;
      debugPrint('Rule search failed: $error');
      // An empty result list and a failed scan look identical in the table, so
      // the failure is stated rather than shown as "no match".
      setState(() {
        _searchResults = const [];
        _searchMatched = 0;
        _searchTruncated = false;
        _searching = false;
        _searchFailed = true;
      });
    }
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    _runSearch('');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final spacing = ResponsiveUtils.getSpacing(context);
    final radius = ResponsiveUtils.getBorderRadius(context);
    final padding = ResponsiveUtils.getCardPadding(context);

    // Narrow subscriptions on purpose: this provider notifies for every
    // traffic sample, and none of those move a warning or a rule set.
    final warnings = context.select<AppStateProvider, List<String>>(
      (appState) => appState.configWarnings,
    );
    final report = context.select<AppStateProvider, RuleProviderReport>(
      (appState) => appState.ruleSetReport,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n?.rulesTitle ?? 'Rules'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => popOrGoSettings(context),
        ),
        actions: [
          IconButton(
            tooltip: l10n?.rulesOpen ?? 'Rule diagnostics',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refreshTable,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refreshTable,
        child: CustomScrollView(
          controller: _scrollController,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                padding.left,
                padding.top,
                padding.right,
                0,
              ),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  Text(
                    l10n?.rulesSubtitle ??
                        'Evaluated top to bottom; the first match decides the '
                            'outbound',
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
                  _searchField(context, l10n),
                  const SizedBox(height: 8),
                  _statusBanner(context, l10n),
                ]),
              ),
            ),
            _ruleSliver(context, padding, radius),
            SliverToBoxAdapter(child: SizedBox(height: spacing * 2)),
          ],
        ),
      ),
    );
  }

  /// The refresh action: re-runs the search when one is active, and re-reads
  /// the table from the engine otherwise.
  Future<void> _refreshTable() async {
    if (_query.isNotEmpty) {
      await _runSearch(_query);
      return;
    }
    await _loadFirstPage(refresh: true);
  }

  Widget _searchField(BuildContext context, AppLocalizations? l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    return TextField(
      controller: _searchController,
      onChanged: _onSearchChanged,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: l10n?.rulesSearchHint ?? 'Search type, payload or outbound',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close),
                onPressed: _clearSearch,
              ),
        isDense: true,
        filled: true,
        fillColor: colorScheme.surfaceContainerHigh,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  /// What the area under the search box says: the engine error, the search
  /// state, or nothing at all.
  Widget _statusBanner(BuildContext context, AppLocalizations? l10n) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    if (_error != null) {
      return Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        color: colorScheme.errorContainer,
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

    if (_searching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_query.isNotEmpty) {
      if (_searchFailed) {
        return Text(
          l10n?.rulesEngineOff ??
              'The engine is not running, so hit counts are unavailable',
          style: textTheme.bodySmall?.copyWith(color: colorScheme.error),
        );
      }
      return Text(
        _searchMatched == 0
            ? (l10n?.rulesSearchEmpty ?? 'No rule matches that query')
            : (l10n?.rulesSearchSummary(
                    _searchMatched,
                    _searchResults.length,
                  ) ??
                  '$_searchMatched matches'),
        style: textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }

    return const SizedBox.shrink();
  }

  /// The rows themselves: the search results while a query is active, the
  /// paged table otherwise, both through one lazily-built sliver.
  Widget _ruleSliver(BuildContext context, EdgeInsets padding, double radius) {
    final rules = _query.isEmpty ? _rules : _searchResults;

    if (_loading && rules.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 32),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    if (rules.isEmpty) {
      if (_query.isNotEmpty || _error != null) {
        return const SliverToBoxAdapter(child: SizedBox.shrink());
      }
      final l10n = AppLocalizations.of(context);
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Center(
            child: Text(
              l10n?.rulesRulesEmpty ?? 'The engine has no rules loaded',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return SliverPadding(
      padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, 0),
      sliver: SliverList.separated(
        itemCount: rules.length + 1,
        itemBuilder: (context, index) {
          if (index == rules.length) {
            return _listFooter(context);
          }
          return _ruleRow(
            context,
            rules[index],
            _query.isEmpty ? index : null,
            radius,
            isFirst: index == 0,
            isLast: index == rules.length - 1,
          );
        },
        separatorBuilder: (context, index) =>
            const Divider(height: 1, indent: 16, endIndent: 16),
      ),
    );
  }

  /// The line under the last row: loading the next page, the point where
  /// loading stopped, or nothing.
  Widget _listFooter(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final String? note;
    if (_query.isNotEmpty) {
      note = _searchTruncated
          ? (l10n?.rulesSearchTruncated(_searchResults.length) ??
                'Showing the first ${_searchResults.length} matches')
          : null;
    } else if (_rules.length >= _maxLoadedRows && _rules.length < _total) {
      note =
          l10n?.rulesLoadLimitReached(_rules.length, _total) ??
          'Stopped after ${_rules.length} of $_total rules';
    } else {
      note = null;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Column(
        children: [
          if (_query.isEmpty && _loadingMore)
            const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (note != null)
            Text(
              note,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }

  Widget _summaryRow(BuildContext context, RuleProviderReport report) {
    final l10n = AppLocalizations.of(context);
    final failed = report.failed.length;

    return Row(
      children: [
        Expanded(
          child: _summaryTile(
            context,
            icon: Icons.list_alt_outlined,
            label: l10n?.rulesSummaryRules ?? 'Rules',
            value: _error != null ? '—' : _total.toString(),
          ),
        ),
        SizedBox(width: ResponsiveUtils.getSpacing(context)),
        Expanded(
          child: _summaryTile(
            context,
            icon: Icons.bolt_outlined,
            label: l10n?.rulesSummaryHits ?? 'Matches',
            value: _error != null ? '—' : _totalMatches.toString(),
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

  /// One row. [index] is null in search results, where the position in the
  /// table is not known and a made-up number would be a lie.
  Widget _ruleRow(
    BuildContext context,
    RuleDto rule,
    int? index,
    double radius, {
    required bool isFirst,
    required bool isLast,
  }) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final veil = theme.extension<WallpaperSurface>();
    final payload = rule.payload.isEmpty ? '—' : rule.payload;
    final hits = rule.matchedCount;

    return Material(
      color:
          veil?.veil(colorScheme.surfaceContainerLow) ??
          colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(isFirst ? radius : 0),
        bottom: Radius.circular(isLast ? radius : 0),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        dense: true,
        leading: SizedBox(
          width: 34,
          child: Text(
            index == null ? '·' : '#${index + 1}',
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
