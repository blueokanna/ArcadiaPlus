import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:arcadiaplus/src/services/ip_probe_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/utils/responsive_utils.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';
import 'package:arcadiaplus/src/theme/app_motion.dart';
import 'package:arcadiaplus/src/services/proxy_selection_events.dart';

/// Traffic history data point
class TrafficDataPoint {
  final DateTime timestamp;
  final double downloadSpeed;
  final double uploadSpeed;

  TrafficDataPoint({
    required this.timestamp,
    required this.downloadSpeed,
    required this.uploadSpeed,
  });
}

/// Traffic history manager - keeps last N data points
class TrafficHistoryManager {
  static const int maxDataPoints = 60;

  final Queue<TrafficDataPoint> _history = Queue<TrafficDataPoint>();

  void addDataPointWithSpeed(BigInt downloadSpeed, BigInt uploadSpeed) {
    _history.add(
      TrafficDataPoint(
        timestamp: DateTime.now(),
        downloadSpeed: downloadSpeed.toDouble(),
        uploadSpeed: uploadSpeed.toDouble(),
      ),
    );

    while (_history.length > maxDataPoints) {
      _history.removeFirst();
    }
  }

  void addDataPoint(TrafficStats stats) {
    addDataPointWithSpeed(stats.downloadSpeed, stats.uploadSpeed);
  }

  List<FlSpot> getDownloadSpots() {
    final historyList = _history.toList();
    return List.generate(historyList.length, (index) {
      final speed = historyList[index].downloadSpeed / 1024;
      return FlSpot(index.toDouble(), speed);
    });
  }

  List<FlSpot> getUploadSpots() {
    final historyList = _history.toList();
    return List.generate(historyList.length, (index) {
      final speed = historyList[index].uploadSpeed / 1024;
      return FlSpot(index.toDouble(), speed);
    });
  }

  double getMaxSpeed() {
    if (_history.isEmpty) return 100;
    double max = 0;
    for (final point in _history) {
      final downloadKb = point.downloadSpeed / 1024;
      final uploadKb = point.uploadSpeed / 1024;
      if (downloadKb > max) max = downloadKb;
      if (uploadKb > max) max = uploadKb;
    }
    return max < 10 ? 10 : max * 1.2;
  }

  void clear() {
    _history.clear();
  }
}

final trafficHistoryManager = TrafficHistoryManager();

class TrafficChart extends StatefulWidget {
  final TrafficStats trafficStats;
  final BigInt downloadSpeed;
  final BigInt uploadSpeed;
  final bool isProxyRunning;
  final int proxyPort;
  final IpProbeClientFactory ipClientFactory;

  const TrafficChart({
    super.key,
    required this.trafficStats,
    required this.downloadSpeed,
    required this.uploadSpeed,
    this.isProxyRunning = false,
    this.proxyPort = 7890,
    this.ipClientFactory = createIpProbeClient,
  });

  @override
  State<TrafficChart> createState() => _TrafficChartState();
}

class IpInfo {
  final String ip;
  final String? country;
  final String? countryCode;
  final String? city;
  final String? isp;
  final String? organization;
  final bool isIpv6;

  IpInfo({
    required this.ip,
    this.country,
    this.countryCode,
    this.city,
    this.isp,
    this.organization,
    this.isIpv6 = false,
  });

  String get location {
    final parts = <String>[];
    if (city != null && city!.isNotEmpty) parts.add(city!);
    if (country != null && country!.isNotEmpty) parts.add(country!);
    return parts.isEmpty ? 'Unknown' : parts.join(', ');
  }

  String get flag {
    if (countryCode == null || countryCode!.length != 2) return '🌐';
    // Convert country code to flag emoji
    final code = countryCode!.toUpperCase();
    final firstLetter = code.codeUnitAt(0) - 0x41 + 0x1F1E6;
    final secondLetter = code.codeUnitAt(1) - 0x41 + 0x1F1E6;
    return String.fromCharCodes([firstLetter, secondLetter]);
  }
}

/// Global IP info cache to avoid repeated requests
class _IpInfoCache {
  IpInfo? ipv4Info;
  IpInfo? ipv6Info;
  DateTime? lastFetchTime;
  bool? lastProxyState;
  int? lastProxyPort;
  int? lastSelectionRevision;

  static const cacheDuration = Duration(minutes: 5);

  bool shouldRefresh(bool isProxyRunning, int proxyPort) {
    if (lastProxyPort != proxyPort ||
        lastSelectionRevision != ProxySelectionEvents.revision) {
      return true;
    }
    if (lastProxyState != null && lastProxyState != isProxyRunning) {
      return true;
    }
    if (lastFetchTime == null) {
      return true;
    }
    return DateTime.now().difference(lastFetchTime!) > cacheDuration;
  }

  void update({
    IpInfo? ipv4,
    IpInfo? ipv6,
    required bool proxyState,
    required int proxyPort,
  }) {
    ipv4Info = ipv4;
    ipv6Info = ipv6;
    lastFetchTime = DateTime.now();
    lastProxyState = proxyState;
    lastProxyPort = proxyPort;
    lastSelectionRevision = ProxySelectionEvents.revision;
  }

  void clear() {
    ipv4Info = null;
    ipv6Info = null;
    lastFetchTime = null;
    lastProxyState = null;
    lastProxyPort = null;
    lastSelectionRevision = null;
  }
}

final _ipInfoCache = _IpInfoCache();

class _TrafficChartState extends State<TrafficChart> {
  final _totalsScrollController = ScrollController();
  Timer? _ipRefreshTimer;
  final _clients = <Dio>{};
  IpInfo? _ipv4Info;
  IpInfo? _ipv6Info;
  bool _isLoadingIp = false;
  int _ipGeneration = 0;
  bool _isCurrentIpRequest(int generation) =>
      mounted && generation == _ipGeneration;
  String? _ipError;
  StreamSubscription<String>? _proxySelectionSubscription;

  @override
  void initState() {
    super.initState();
    _recordSample();
    if (!_ipInfoCache.shouldRefresh(widget.isProxyRunning, widget.proxyPort)) {
      _ipv4Info = _ipInfoCache.ipv4Info;
      _ipv6Info = _ipInfoCache.ipv6Info;
    }

    if (_ipInfoCache.shouldRefresh(widget.isProxyRunning, widget.proxyPort)) {
      _fetchIpInfo();
    }

    _proxySelectionSubscription = ProxySelectionEvents.changes.listen((_) {
      // Clear cache and refresh IP when proxy selection changes
      _ipInfoCache.clear();
      setState(() => _scheduleIpRefresh(const Duration(milliseconds: 800)));
    });
  }

  DateTime? _lastSampleAt;

  /// Record one traffic sample.
  ///
  /// Spaced by time rather than by rebuild: a rebuild caused by something other
  /// than a fresh sample — a port change, a theme change — would otherwise
  /// insert a second point for the same instant and compress the timeline.
  void _recordSample() {
    final now = DateTime.now();
    final last = _lastSampleAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 900)) {
      return;
    }
    _lastSampleAt = now;
    trafficHistoryManager.addDataPointWithSpeed(
      widget.downloadSpeed,
      widget.uploadSpeed,
    );
  }

  void _scheduleIpRefresh(Duration delay) {
    _ipGeneration++;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
    _isLoadingIp = false;
    _ipv4Info = null;
    _ipv6Info = null;
    _ipError = null;
    _ipRefreshTimer?.cancel();
    _ipRefreshTimer = Timer(delay, _fetchIpInfo);
  }

  @override
  void didUpdateWidget(TrafficChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    _recordSample();
    if (widget.isProxyRunning != oldWidget.isProxyRunning ||
        widget.proxyPort != oldWidget.proxyPort) {
      _ipInfoCache.clear();
      _scheduleIpRefresh(const Duration(milliseconds: 500));
    }
  }

  @override
  void dispose() {
    _totalsScrollController.dispose();
    _ipRefreshTimer?.cancel();
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
    _proxySelectionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _fetchIpInfo() async {
    if (!mounted || _isLoadingIp) return;
    final generation = ++_ipGeneration;
    setState(() {
      _isLoadingIp = true;
      _ipError = null;
    });

    await Future.wait([_fetchIpv4Info(generation), _fetchIpv6Info(generation)]);

    if (!_isCurrentIpRequest(generation)) return;
    _ipInfoCache.update(
      ipv4: _ipv4Info,
      ipv6: _ipv6Info,
      proxyState: widget.isProxyRunning,
      proxyPort: widget.proxyPort,
    );

    if (mounted) {
      setState(() => _isLoadingIp = false);
    }
  }

  /// Run a one-shot request on a client that is always torn down.
  ///
  /// `close(force: true)` closes the adapter's `HttpClient` — sockets
  /// included — rather than only detaching Dio from it, and it runs even when
  /// the request throws. Both properties matter here: a probe that times out
  /// or fails must not leave a socket behind, and `close()` without `force`
  /// leaves exactly that behind.
  Future<T> _oneShot<T>(
    int generation,
    bool useProxy,
    Future<T> Function(Dio dio) request,
  ) async {
    if (!_isCurrentIpRequest(generation)) {
      throw StateError('IP request is no longer current');
    }
    final dio = widget.ipClientFactory(useProxy, widget.proxyPort);
    _clients.add(dio);
    try {
      return await request(dio);
    } finally {
      _clients.remove(dio);
      dio.close(force: true);
    }
  }

  Future<void> _fetchIpv4Info(int generation) async {
    try {
      final response = await _oneShot(
        generation,
        widget.isProxyRunning,
        (dio) => dio.get('https://api.ip.sb/geoip'),
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;

        if (_isCurrentIpRequest(generation)) {
          setState(() {
            _ipv4Info = IpInfo(
              ip: data['ip']?.toString() ?? '',
              country: data['country']?.toString(),
              countryCode: data['country_code']?.toString(),
              city: data['city']?.toString(),
              isp: data['isp']?.toString(),
              organization: data['organization']?.toString(),
              isIpv6: (data['ip']?.toString() ?? '').contains(':'),
            );
            _ipError = null;
          });
        }
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        if (_isCurrentIpRequest(generation)) {
          setState(() {
            _ipError = 'Connect Timeout';
          });
        }
        return;
      }
      try {
        final response = await _oneShot(
          generation,
          widget.isProxyRunning,
          (dio) => dio.get('https://api.ip.sb/ip'),
        );
        if (response.statusCode == 200) {
          final body = response.data.toString().trim();
          if (_isCurrentIpRequest(generation)) {
            setState(() {
              _ipv4Info = IpInfo(ip: body);
              _ipError = null;
            });
          }
        }
      } on DioException catch (e2) {
        if (e2.type == DioExceptionType.connectionTimeout ||
            e2.type == DioExceptionType.receiveTimeout ||
            e2.type == DioExceptionType.sendTimeout) {
          if (_isCurrentIpRequest(generation)) {
            setState(() {
              _ipError = 'Connect Timeout';
            });
          }
        } else {
          debugPrint('Failed to fetch IPv4 info: $e2');
          if (_isCurrentIpRequest(generation)) {
            setState(() {
              _ipError = 'Network Error';
            });
          }
        }
      } catch (fallbackError) {
        debugPrint('Failed to fetch IPv4 info: $fallbackError');
      }
    } catch (e) {
      debugPrint('Failed to fetch IPv4 info: $e');
      if (_isCurrentIpRequest(generation)) {
        setState(() {
          _ipError = 'Network Error';
        });
      }
    }
  }

  Future<void> _fetchIpv6Info(int generation) async {
    try {
      final response = await _oneShot(
        generation,
        widget.isProxyRunning,
        (dio) => dio.get('https://api-ipv6.ip.sb/geoip'),
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final ip = data['ip']?.toString() ?? '';

        if (ip.contains(':') && _isCurrentIpRequest(generation)) {
          setState(() {
            _ipv6Info = IpInfo(
              ip: ip,
              country: data['country']?.toString(),
              countryCode: data['country_code']?.toString(),
              city: data['city']?.toString(),
              isp: data['isp']?.toString(),
              organization: data['organization']?.toString(),
              isIpv6: true,
            );
          });
        }
      }
    } catch (e) {
      debugPrint('IPv6 not available: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);
    final spacing = ResponsiveUtils.getSpacing(context);
    final borderRadius = ResponsiveUtils.getBorderRadius(context);
    final cardPadding = ResponsiveUtils.getCardPadding(context);
    final chartHeight = ResponsiveUtils.getTrafficChartHeight(context);
    final chinese = l10n?.locale.languageCode == 'zh';

    final downloadSpots = trafficHistoryManager.getDownloadSpots();
    final uploadSpots = trafficHistoryManager.getUploadSpots();
    final maxY = trafficHistoryManager.getMaxSpeed();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final cards = <Widget>[
              _TrafficStatCard(
                icon: Icons.arrow_downward_rounded,
                label: l10n?.download ?? 'Download',
                speed: _formatSpeed(widget.downloadSpeed),
                total: _formatBytes(widget.trafficStats.download),
                color: colorScheme.primary,
                colorScheme: colorScheme,
                textTheme: textTheme,
                isActive: widget.downloadSpeed > BigInt.zero,
              ),
              _TrafficStatCard(
                icon: Icons.arrow_upward_rounded,
                label: l10n?.upload ?? 'Upload',
                speed: _formatSpeed(widget.uploadSpeed),
                total: _formatBytes(widget.trafficStats.upload),
                color: colorScheme.tertiary,
                colorScheme: colorScheme,
                textTheme: textTheme,
                isActive: widget.uploadSpeed > BigInt.zero,
              ),
              Tooltip(
                message: chinese
                    ? '本次运行经直连出口传输的上传与下载之和，包含局域网及其他直连流量；不是 IP 地理归属统计。'
                    : 'Session upload + download through direct exits, including LAN and other direct traffic; not IP geolocation.',
                child: _TrafficStatCard(
                  icon: Icons.home_work_outlined,
                  label: chinese ? '国内总流量' : 'Domestic total',
                  speed: _formatBytes(
                    widget.trafficStats.directUpload +
                        widget.trafficStats.directDownload,
                  ),
                  total: '',
                  detail: chinese ? '本次运行 · 直连' : 'Session · Direct',
                  color: colorScheme.secondary,
                  colorScheme: colorScheme,
                  textTheme: textTheme,
                  isActive: false,
                ),
              ),
              _TrafficStatCard(
                icon: Icons.public_rounded,
                label: chinese ? '代理总流量' : 'Proxy total',
                speed: _formatBytes(
                  widget.trafficStats.proxyUpload +
                      widget.trafficStats.proxyDownload,
                ),
                total: '',
                detail: chinese ? '本次运行 · 代理' : 'Session · Proxy',
                color: colorScheme.primary,
                colorScheme: colorScheme,
                textTheme: textTheme,
                isActive: false,
              ),
            ];
            final minimumWidth =
                164.0 *
                (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
                  1.0,
                  2.0,
                );
            final width = ((constraints.maxWidth - spacing * 3) / 4).clamp(
              minimumWidth,
              double.infinity,
            );
            return Scrollbar(
              controller: _totalsScrollController,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _totalsScrollController,
                key: const ValueKey('traffic-totals-row'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) SizedBox(width: spacing),
                      SizedBox(width: width, child: cards[i]),
                    ],
                  ],
                ),
              ),
            );
          },
        ),

        SizedBox(height: spacing),

        _IpInfoCard(
          ipv4Info: _ipv4Info,
          ipv6Info: _ipv6Info,
          isLoading: _isLoadingIp,
          isProxyRunning: widget.isProxyRunning,
          onRefresh: _fetchIpInfo,
          colorScheme: colorScheme,
          textTheme: textTheme,
          error: _ipError,
        ),

        SizedBox(height: spacing * 2),

        Card(
          elevation: 0,
          color: colorScheme.surfaceContainerLow,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(borderRadius),
          ),
          child: Padding(
            padding: cardPadding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.show_chart_rounded,
                          size: 18,
                          color: colorScheme.primary,
                        ),
                        SizedBox(width: spacing),
                        Expanded(
                          child: Text(
                            l10n?.realTimeTraffic ?? 'Real-time Traffic',
                            style: textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _ChartLegend(
                      downloadColor: colorScheme.primary,
                      uploadColor: colorScheme.tertiary,
                      downloadLabel: l10n?.download ?? 'Download',
                      uploadLabel: l10n?.upload ?? 'Upload',
                    ),
                  ],
                ),

                SizedBox(height: spacing * 2),

                SizedBox(
                  height: chartHeight - 60,
                  child: downloadSpots.isEmpty || uploadSpots.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.area_chart_rounded,
                                size: 32,
                                color: colorScheme.outlineVariant,
                              ),
                              SizedBox(height: spacing),
                              Text(
                                l10n?.noData ?? 'No data',
                                style: TextStyle(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        )
                      : LineChart(
                          LineChartData(
                            gridData: FlGridData(
                              show: true,
                              drawVerticalLine: false,
                              horizontalInterval: maxY / 4,
                              getDrawingHorizontalLine: (value) {
                                return FlLine(
                                  color: colorScheme.outlineVariant.withValues(
                                    alpha: 0.2,
                                  ),
                                  strokeWidth: 1,
                                  dashArray: [5, 5],
                                );
                              },
                            ),
                            titlesData: FlTitlesData(
                              show: true,
                              rightTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              topTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              bottomTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 42,
                                  getTitlesWidget: (value, meta) {
                                    return Text(
                                      _formatSpeedShort(value),
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            borderData: FlBorderData(show: false),
                            minX: 0,
                            maxX:
                                TrafficHistoryManager.maxDataPoints.toDouble() -
                                1,
                            minY: 0,
                            maxY: maxY,
                            lineTouchData: LineTouchData(
                              touchTooltipData: LineTouchTooltipData(
                                getTooltipItems: (touchedSpots) {
                                  return touchedSpots.map((spot) {
                                    final isDownload = spot.barIndex == 0;
                                    return LineTooltipItem(
                                      _formatSpeedValue(spot.y * 1024),
                                      TextStyle(
                                        color: isDownload
                                            ? colorScheme.primary
                                            : colorScheme.tertiary,
                                        fontWeight: FontWeight.w600,
                                        fontSize: 12,
                                      ),
                                    );
                                  }).toList();
                                },
                              ),
                            ),
                            lineBarsData: [
                              LineChartBarData(
                                spots: downloadSpots.length >= 2
                                    ? downloadSpots
                                    : [const FlSpot(0, 0), const FlSpot(1, 0)],
                                isCurved: true,
                                curveSmoothness: 0.35,
                                color: colorScheme.primary,
                                barWidth: 2.5,
                                isStrokeCapRound: true,
                                dotData: const FlDotData(show: false),
                                belowBarData: BarAreaData(
                                  show: true,
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      colorScheme.primary.withValues(
                                        alpha: 0.3,
                                      ),
                                      colorScheme.primary.withValues(
                                        alpha: 0.0,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              LineChartBarData(
                                spots: uploadSpots.length >= 2
                                    ? uploadSpots
                                    : [const FlSpot(0, 0), const FlSpot(1, 0)],
                                isCurved: true,
                                curveSmoothness: 0.35,
                                color: colorScheme.tertiary,
                                barWidth: 2.5,
                                isStrokeCapRound: true,
                                dotData: const FlDotData(show: false),
                                belowBarData: BarAreaData(
                                  show: true,
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      colorScheme.tertiary.withValues(
                                        alpha: 0.2,
                                      ),
                                      colorScheme.tertiary.withValues(
                                        alpha: 0.0,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          duration: AppMotion.duration(context),
                        ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String _formatBytes(BigInt bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unitIndex]}';
  }

  String _formatSpeed(BigInt bytesPerSecond) {
    return '${_formatBytes(bytesPerSecond)}/s';
  }

  String _formatSpeedShort(double kbPerSecond) {
    if (kbPerSecond < 1024) {
      return '${kbPerSecond.toStringAsFixed(0)}K';
    } else {
      return '${(kbPerSecond / 1024).toStringAsFixed(1)}M';
    }
  }

  String _formatSpeedValue(double bytesPerSecond) {
    const units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
    var value = bytesPerSecond;
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unitIndex]}';
  }
}

class _TrafficStatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String speed;
  final String total;
  final String? detail;
  final Color color;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final bool isActive;

  const _TrafficStatCard({
    required this.icon,
    required this.label,
    required this.speed,
    required this.total,
    this.detail,
    required this.color,
    required this.colorScheme,
    required this.textTheme,
    required this.isActive,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = ResponsiveUtils.getBorderRadius(context);
    final spacing = ResponsiveUtils.getSpacing(context);

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: Padding(
        padding: EdgeInsets.all(spacing * 1.5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                AnimatedContainer(
                  duration: AppMotion.duration(context, AppMotion.short),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: isActive ? 0.16 : 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: textTheme.labelMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),

            SizedBox(height: spacing),

            // 速度
            Text(
              speed,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),

            SizedBox(height: spacing * 0.5),

            Row(
              children: [
                Icon(
                  Icons.data_usage_rounded,
                  size: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
                SizedBox(width: spacing * 0.5),
                Expanded(
                  child: Text(
                    detail ??
                        '${AppLocalizations.of(context)?.total ?? "Total"}: $total',
                    style: textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// IP 信息卡片 - 显示 IPv4/IPv6 和地理位置
class _IpInfoCard extends StatelessWidget {
  final IpInfo? ipv4Info;
  final IpInfo? ipv6Info;
  final bool isLoading;
  final bool isProxyRunning;
  final VoidCallback onRefresh;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final String? error;

  const _IpInfoCard({
    required this.ipv4Info,
    required this.ipv6Info,
    required this.isLoading,
    required this.isProxyRunning,
    required this.onRefresh,
    required this.colorScheme,
    required this.textTheme,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = ResponsiveUtils.getBorderRadius(context);
    final spacing = ResponsiveUtils.getSpacing(context);
    final statusColor = isProxyRunning ? Colors.green : colorScheme.outline;
    final l10n = AppLocalizations.of(context);
    final primaryInfo = ipv4Info ?? ipv6Info;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(borderRadius),
      ),
      child: InkWell(
        onTap: onRefresh,
        onLongPress: primaryInfo != null
            ? () {
                Clipboard.setData(ClipboardData(text: primaryInfo.ip));
                AnimationUtils.lightHaptic();
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(l10n?.ipCopied ?? 'IP copied'),
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    duration: const Duration(seconds: 2),
                  ),
                );
              }
            : null,
        borderRadius: BorderRadius.circular(borderRadius),
        child: Padding(
          padding: EdgeInsets.all(spacing * 1.5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 状态图标
                  Container(
                    padding: EdgeInsets.all(spacing * 0.8),
                    decoration: BoxDecoration(
                      color: isProxyRunning
                          ? Colors.green.withValues(alpha: 0.12)
                          : colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(borderRadius * 0.5),
                    ),
                    child: Icon(
                      Icons.public_rounded,
                      size: 18,
                      color: statusColor,
                    ),
                  ),
                  SizedBox(width: spacing),
                  Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: spacing,
                      vertical: spacing * 0.4,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(borderRadius * 0.5),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: statusColor,
                          ),
                        ),
                        SizedBox(width: spacing * 0.5),
                        Text(
                          isProxyRunning
                              ? (l10n?.proxy ?? 'Proxy')
                              : (l10n?.direct ?? 'Direct'),
                          style: textTheme.labelSmall?.copyWith(
                            color: statusColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (primaryInfo != null) ...[
                    Text(
                      primaryInfo.flag,
                      style: const TextStyle(fontSize: 16),
                    ),
                    SizedBox(width: spacing * 0.5),
                    Flexible(
                      child: Text(
                        primaryInfo.location,
                        style: textTheme.labelMedium?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                  if (isLoading) ...[
                    SizedBox(width: spacing),
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.primary,
                      ),
                    ),
                  ],
                ],
              ),

              SizedBox(height: spacing),

              if (ipv4Info != null)
                _buildIpRow(
                  context,
                  label: 'IPv4',
                  ip: ipv4Info!.ip,
                  isp: ipv4Info!.isp,
                  isProxyRunning: isProxyRunning,
                ),

              // IPv6 信息
              if (ipv6Info != null) ...[
                if (ipv4Info != null) SizedBox(height: spacing * 0.75),
                _buildIpRow(
                  context,
                  label: 'IPv6',
                  ip: ipv6Info!.ip,
                  isp: ipv6Info!.isp,
                  isProxyRunning: isProxyRunning,
                ),
              ],

              if (error != null && ipv4Info == null && ipv6Info == null)
                _AddressText(
                  text: error!,
                  isp: null,
                  isProxyRunning: false,
                  colorScheme: colorScheme,
                  textTheme: textTheme,
                  isError: true,
                ),

              if (ipv4Info == null && ipv6Info == null && error == null)
                Text(
                  '--',
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildIpRow(
    BuildContext context, {
    required String label,
    required String ip,
    String? isp,
    required bool isProxyRunning,
  }) {
    final spacing = ResponsiveUtils.getSpacing(context);
    final isIpv6 = label == 'IPv6';

    return Row(
      children: [
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: spacing * 0.75,
            vertical: spacing * 0.25,
          ),
          decoration: BoxDecoration(
            color: label == 'IPv4'
                ? colorScheme.primaryContainer
                : colorScheme.tertiaryContainer,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            label,
            style: textTheme.labelSmall?.copyWith(
              color: label == 'IPv4'
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onTertiaryContainer,
              fontWeight: FontWeight.w600,
              fontSize: 10,
            ),
          ),
        ),
        SizedBox(width: spacing),
        Expanded(
          child: isIpv6
              ? _AddressText(
                  text: ip,
                  isp: isp,
                  isProxyRunning: isProxyRunning,
                  colorScheme: colorScheme,
                  textTheme: textTheme,
                )
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  child: Row(
                    children: [
                      Text(
                        ip,
                        style: textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: isProxyRunning
                              ? colorScheme.primary
                              : colorScheme.onSurface,
                        ),
                      ),
                      if (isp != null && isp.isNotEmpty) ...[
                        SizedBox(width: spacing),
                        Text(
                          '($isp)',
                          style: textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// 自动滚动文本组件 - 用于长 IPv6 地址
class _AddressText extends StatelessWidget {
  final String text;
  final String? isp;
  final bool isProxyRunning;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final bool isError;

  const _AddressText({
    required this.text,
    this.isp,
    required this.isProxyRunning,
    required this.colorScheme,
    required this.textTheme,
    this.isError = false,
  });

  @override
  Widget build(BuildContext context) {
    final spacing = ResponsiveUtils.getSpacing(context);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          Text(
            text,
            style: textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: isError
                  ? colorScheme.error
                  : isProxyRunning
                  ? colorScheme.primary
                  : colorScheme.onSurface,
            ),
          ),
          if (isp != null && isp!.isNotEmpty) ...[
            SizedBox(width: spacing),
            Text(
              '($isp)',
              style: textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Chart legend widget
class _ChartLegend extends StatelessWidget {
  final Color downloadColor;
  final Color uploadColor;
  final String downloadLabel;
  final String uploadLabel;

  const _ChartLegend({
    required this.downloadColor,
    required this.uploadColor,
    required this.downloadLabel,
    required this.uploadLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _LegendDot(color: downloadColor, label: downloadLabel),
        _LegendDot(color: uploadColor, label: uploadLabel),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: textTheme.labelSmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
