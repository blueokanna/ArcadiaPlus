import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:arcadia_plus/src/rust/api.dart' as rust_api;
import 'package:arcadia_plus/src/utils/app_lifecycle.dart';
import 'package:arcadia_plus/src/utils/platform_utils.dart';
import 'package:arcadia_plus/src/l10n/app_localizations.dart';
import 'package:arcadia_plus/src/services/native_core_service.dart';

class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key});

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  List<String> _logs = [];
  bool _isLoading = true;
  bool _autoRefresh = true;
  Timer? _refreshTimer;
  final ScrollController _scrollController = ScrollController();
  String _filterLevel = 'all';

  /// The filtered view is derived, and deriving it costs a pass over every
  /// line with several `contains` checks each. Caching it keeps that pass out
  /// of `build`, which otherwise repeated it on every frame of a scroll.
  List<String>? _filteredCache;
  String? _filteredCacheLevel;

  /// How often the log buffer is re-read while the screen is visible.
  static const Duration _refreshInterval = Duration(seconds: 3);

  @override
  void initState() {
    super.initState();
    _loadLogs();
    AppLifecycle.instance.active.addListener(_syncAutoRefresh);
    _syncAutoRefresh();
  }

  @override
  void dispose() {
    AppLifecycle.instance.active.removeListener(_syncAutoRefresh);
    _refreshTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  /// The log poll runs only while the log view can actually be seen and the
  /// user has left auto-refresh on.
  ///
  /// It used to be a flat two-second timer, alive for as long as the screen
  /// existed: two thousand lines pulled across the bridge every tick, and a
  /// rebuild and re-filter of all of them, to redraw text that had not moved.
  /// Most of that work disappeared the moment it was made conditional.
  void _syncAutoRefresh() {
    if (_autoRefresh && AppLifecycle.instance.isActive) {
      _refreshTimer ??= Timer.periodic(_refreshInterval, (_) {
        if (mounted) _loadLogs(scrollToBottom: false);
      });
    } else {
      _refreshTimer?.cancel();
      _refreshTimer = null;
    }
  }

  Future<void> _loadLogs({bool scrollToBottom = true}) async {
    try {
      // Check if RustLib is initialized
      if (!NativeCoreService.instance.isReady) {
        if (mounted) {
          setState(() {
            _logs = ['Rust library not initialized. Please restart the app.'];
            _isLoading = false;
          });
        }
        return;
      }

      // Request more logs (up to 2000) to show more history
      final logs = await rust_api.getLogs(lines: 2000);
      if (!mounted) return;

      // Nothing new to show: leave the list alone. This is both the common
      // case for an idle app and the expensive one — a fresh list means
      // re-filtering every line and rebuilding the list view.
      if (listEquals(logs, _logs)) return;

      setState(() {
        _logs = logs;
        _filteredCache = null;
        _filteredCacheLevel = null;
        _isLoading = false;
      });
      if (scrollToBottom && _scrollController.hasClients) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _logs = ['Error loading logs: $e'];
          _filteredCache = null;
          _filteredCacheLevel = null;
          _isLoading = false;
        });
      }
    }
  }

  List<String> get _filteredLogs {
    final cached = _filteredCache;
    if (cached != null && _filteredCacheLevel == _filterLevel) return cached;

    final filtered = _filterLevel == 'all'
        ? _logs
        : _logs.where((log) {
            // Uppercased once per line rather than once per pattern.
            final upperLog = log.toUpperCase();
            final isError = upperLog.contains('ERROR');
            final isWarning = upperLog.contains('WARN');
            final isInfo = upperLog.contains('INFO');
            switch (_filterLevel) {
              case 'error':
                return isError;
              case 'warn':
                return isError || isWarning;
              case 'info':
                return isError || isWarning || isInfo;
              case 'debug':
                return true; // Show all for debug
              default:
                return true;
            }
          }).toList();

    _filteredCache = filtered;
    _filteredCacheLevel = _filterLevel;
    return filtered;
  }

  Color _getLogColor(String log, ColorScheme colorScheme) {
    final upperLog = log.toUpperCase();
    if (upperLog.contains('[ERROR]') || upperLog.contains('ERROR')) {
      return colorScheme.error;
    } else if (upperLog.contains('[WARN]') || upperLog.contains('WARN')) {
      return Colors.orange;
    } else if (upperLog.contains('[INFO]') || upperLog.contains('INFO')) {
      return colorScheme.primary;
    } else if (upperLog.contains('[DEBUG]') || upperLog.contains('DEBUG')) {
      return colorScheme.tertiary;
    }
    return colorScheme.onSurface;
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);
    final filteredLogs = _filteredLogs;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          l10n?.logs ?? '日志',
          style: textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          // Filter dropdown
          PopupMenuButton<String>(
            icon: const Icon(Icons.filter_list),
            tooltip: '过滤日志',
            onSelected: (value) {
              setState(() {
                _filterLevel = value;
              });
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'all',
                child: Row(
                  children: [
                    if (_filterLevel == 'all')
                      const Icon(Icons.check, size: 18),
                    const SizedBox(width: 8),
                    const Text('全部'),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'error',
                child: Row(
                  children: [
                    if (_filterLevel == 'error')
                      const Icon(Icons.check, size: 18),
                    const SizedBox(width: 8),
                    Text('ERROR', style: TextStyle(color: colorScheme.error)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'warn',
                child: Row(
                  children: [
                    if (_filterLevel == 'warn')
                      const Icon(Icons.check, size: 18),
                    const SizedBox(width: 8),
                    const Text('WARN+', style: TextStyle(color: Colors.orange)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'info',
                child: Row(
                  children: [
                    if (_filterLevel == 'info')
                      const Icon(Icons.check, size: 18),
                    const SizedBox(width: 8),
                    Text('INFO+', style: TextStyle(color: colorScheme.primary)),
                  ],
                ),
              ),
            ],
          ),
          // Auto refresh toggle
          IconButton(
            icon: Icon(_autoRefresh ? Icons.sync : Icons.sync_disabled),
            tooltip: _autoRefresh ? '自动刷新: 开' : '自动刷新: 关',
            onPressed: () {
              setState(() {
                _autoRefresh = !_autoRefresh;
              });
              _syncAutoRefresh();
            },
          ),
          // Manual refresh
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: l10n?.refresh ?? '刷新',
            onPressed: () => _loadLogs(),
          ),
          // Clear logs
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: l10n?.clearLogs ?? '清除日志',
            onPressed: () {
              setState(() {
                _logs = [];
              });
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                // Status bar
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  color: colorScheme.surfaceContainerLow,
                  child: Row(
                    children: [
                      Icon(
                        _autoRefresh
                            ? Icons.fiber_manual_record
                            : Icons.pause_circle_outline,
                        size: 12,
                        color: _autoRefresh
                            ? Colors.green
                            : colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '${filteredLogs.length} ${l10n?.logEntries ?? '条日志'}',
                        style: textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      if (Platform.isAndroid || PlatformUtils.isOHOS)
                        Text(
                          'VPN 模式',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.primary,
                          ),
                        ),
                    ],
                  ),
                ),
                // Log list
                Expanded(
                  child: filteredLogs.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.description_outlined,
                                size: 64,
                                color: colorScheme.onSurfaceVariant.withValues(
                                  alpha: 0.5,
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                l10n?.noLogs ?? '暂无日志',
                                style: textTheme.bodyLarge?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          physics: PlatformUtils.getScrollPhysics(),
                          padding: const EdgeInsets.all(8),
                          itemCount: filteredLogs.length,
                          itemBuilder: (context, index) {
                            final log = filteredLogs[index];
                            return Container(
                              margin: const EdgeInsets.symmetric(vertical: 2),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: colorScheme.surfaceContainerLow,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: SelectableText(
                                log,
                                style: textTheme.bodySmall?.copyWith(
                                  fontFamily: 'monospace',
                                  color: _getLogColor(log, colorScheme),
                                  height: 1.4,
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: () {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        },
        tooltip: '滚动到底部',
        child: const Icon(Icons.arrow_downward),
      ),
    );
  }
}
