import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/utils/responsive_utils.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';
import 'package:arcadiaplus/src/utils/app_lifecycle.dart';
import 'package:arcadiaplus/src/providers/proxies_provider.dart'
    show proxySelectionChangedController;

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

  const TrafficChart({
    super.key,
    required this.trafficStats,
    required this.downloadSpeed,
    required this.uploadSpeed,
    this.isProxyRunning = false,
    this.proxyPort = 7890,
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

  static const cacheDuration = Duration(minutes: 5);

  bool shouldRefresh(bool isProxyRunning) {
    if (lastProxyState != null && lastProxyState != isProxyRunning) {
      return true;
    }
    if (lastFetchTime == null) {
      return true;
    }
    return DateTime.now().difference(lastFetchTime!) > cacheDuration;
  }

  void update({IpInfo? ipv4, IpInfo? ipv6, required bool proxyState}) {
    if (ipv4 != null) ipv4Info = ipv4;
    if (ipv6 != null) ipv6Info = ipv6;
    lastFetchTime = DateTime.now();
    lastProxyState = proxyState;
  }

  void clear() {
    ipv4Info = null;
    ipv6Info = null;
    lastFetchTime = null;
    lastProxyState = null;
  }
}

final _ipInfoCache = _IpInfoCache();

class _TrafficChartState extends State<TrafficChart>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  IpInfo? _ipv4Info;
  IpInfo? _ipv6Info;
  bool _isLoadingIp = false;
  String? _ipError;
  StreamSubscription<String>? _proxySelectionSubscription;

  @override
  void initState() {
    super.initState();
    _recordSample();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    // The pulse marks "traffic is moving", so it has to be tied to traffic
    // rather than to the widget's lifetime.
    AppLifecycle.instance.active.addListener(_syncPulse);
    _syncPulse();

    if (_ipInfoCache.ipv4Info != null || _ipInfoCache.ipv6Info != null) {
      _ipv4Info = _ipInfoCache.ipv4Info;
      _ipv6Info = _ipInfoCache.ipv6Info;
    }

    if (_ipInfoCache.shouldRefresh(widget.isProxyRunning)) {
      _fetchIpInfo();
    }

    _proxySelectionSubscription = proxySelectionChangedController.stream.listen(
      (_) {
        // Clear cache and refresh IP when proxy selection changes
        _ipInfoCache.clear();
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) _fetchIpInfo();
        });
      },
    );
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

  /// Whether the pulse has any reason to run: traffic flowing, proxy up, app
  /// on screen. Anything else means the animation would be paying for a
  /// repaint nobody can see a difference in.
  bool get _pulseWanted =>
      mounted &&
      AppLifecycle.instance.isActive &&
      widget.isProxyRunning &&
      (widget.downloadSpeed > BigInt.zero || widget.uploadSpeed > BigInt.zero);

  void _syncPulse() {
    if (!mounted) return;
    if (_pulseWanted) {
      if (!_pulseController.isAnimating) {
        _pulseController.repeat(reverse: true);
      }
    } else if (_pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.value = 0;
    }
  }

  @override
  void didUpdateWidget(TrafficChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.downloadSpeed != oldWidget.downloadSpeed ||
        widget.uploadSpeed != oldWidget.uploadSpeed) {
      _recordSample();
    }
    if (widget.isProxyRunning != oldWidget.isProxyRunning) {
      _ipInfoCache.clear();
      Future.delayed(const Duration(milliseconds: 500), _fetchIpInfo);
    }
    _syncPulse();
  }

  @override
  void dispose() {
    AppLifecycle.instance.active.removeListener(_syncPulse);
    _pulseController.dispose();
    _proxySelectionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _fetchIpInfo() async {
    if (_isLoadingIp) return;
    setState(() {
      _isLoadingIp = true;
      _ipError = null;
    });

    await Future.wait([_fetchIpv4Info(), _fetchIpv6Info()]);

    _ipInfoCache.update(
      ipv4: _ipv4Info,
      ipv6: _ipv6Info,
      proxyState: widget.isProxyRunning,
    );

    if (mounted) {
      setState(() => _isLoadingIp = false);
    }
  }

  Dio _createDioClient({bool useProxy = false}) {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
        headers: {
          'User-Agent': 'ArcadiaPlus/1.0',
          // A one-shot probe must not park a keep-alive socket: the engine
          // counts live connections, and a socket the server would keep open
          // shows up in that count long after the check finished.
          'Connection': 'close',
        },
      ),
    );

    if (useProxy) {
      final port = widget.proxyPort;
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () {
          final client = HttpClient();
          client.findProxy = (uri) => 'PROXY 127.0.0.1:$port';
          return client;
        },
      );
    }

    return dio;
  }

  /// Run a one-shot request on a client that is always torn down.
  ///
  /// `close(force: true)` closes the adapter's `HttpClient` — sockets
  /// included — rather than only detaching Dio from it, and it runs even when
  /// the request throws. Both properties matter here: a probe that times out
  /// or fails must not leave a socket behind, and `close()` without `force`
  /// leaves exactly that behind.
  Future<T> _oneShot<T>(
    bool useProxy,
    Future<T> Function(Dio dio) request,
  ) async {
    final dio = _createDioClient(useProxy: useProxy);
    try {
      return await request(dio);
    } finally {
      dio.close(force: true);
    }
  }

  Future<void> _fetchIpv4Info() async {
    try {
      final response = await _oneShot(
        widget.isProxyRunning,
        (dio) => dio.get('https://api.ip.sb/geoip'),
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;

        if (mounted) {
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
        if (mounted) {
          setState(() {
            _ipError = 'Connect Timeout';
          });
        }
        return;
      }
      try {
        final response = await _oneShot(
          widget.isProxyRunning,
          (dio) => dio.get('https://api.ip.sb/ip'),
        );
        if (response.statusCode == 200) {
          final body = response.data.toString().trim();
          if (mounted) {
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
          if (mounted) {
            setState(() {
              _ipError = 'Connect Timeout';
            });
          }
        } else {
          debugPrint('Failed to fetch IPv4 info: $e2');
          if (mounted) {
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
      if (mounted) {
        setState(() {
          _ipError = 'Network Error';
        });
      }
    }
  }

  Future<void> _fetchIpv6Info() async {
    try {
      final response = await _oneShot(
        widget.isProxyRunning,
        (dio) => dio.get('https://api-ipv6.ip.sb/geoip'),
      );

      if (response.statusCode == 200) {
        final data = response.data as Map<String, dynamic>;
        final ip = data['ip']?.toString() ?? '';

        if (ip.contains(':') && mounted) {
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

    final downloadSpots = trafficHistoryManager.getDownloadSpots();
    final uploadSpots = trafficHistoryManager.getUploadSpots();
    final maxY = trafficHistoryManager.getMaxSpeed();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _TrafficStatCard(
                icon: Icons.arrow_downward_rounded,
                label: l10n?.download ?? 'Download',
                speed: _formatSpeed(widget.downloadSpeed),
                total: _formatBytes(widget.trafficStats.download),
                color: colorScheme.primary,
                colorScheme: colorScheme,
                textTheme: textTheme,
                pulseController: _pulseController,
                isActive: widget.downloadSpeed > BigInt.zero,
              ),
            ),
            SizedBox(width: spacing),
            Expanded(
              child: _TrafficStatCard(
                icon: Icons.arrow_upward_rounded,
                label: l10n?.upload ?? 'Upload',
                speed: _formatSpeed(widget.uploadSpeed),
                total: _formatBytes(widget.trafficStats.upload),
                color: colorScheme.tertiary,
                colorScheme: colorScheme,
                textTheme: textTheme,
                pulseController: _pulseController,
                isActive: widget.uploadSpeed > BigInt.zero,
              ),
            ),
          ],
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
                Row(
                  children: [
                    Icon(
                      Icons.show_chart_rounded,
                      size: 18,
                      color: colorScheme.primary,
                    ),
                    SizedBox(width: spacing),
                    Text(
                      l10n?.realTimeTraffic ?? 'Real-time Traffic',
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurface,
                      ),
                    ),
                    const Spacer(),
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
                          duration: const Duration(milliseconds: 300),
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
  final Color color;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final AnimationController pulseController;
  final bool isActive;

  const _TrafficStatCard({
    required this.icon,
    required this.label,
    required this.speed,
    required this.total,
    required this.color,
    required this.colorScheme,
    required this.textTheme,
    required this.pulseController,
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
                AnimatedBuilder(
                  animation: pulseController,
                  builder: (context, child) {
                    return Container(
                      padding: EdgeInsets.all(spacing * 0.8),
                      decoration: BoxDecoration(
                        color: isActive
                            ? color.withValues(
                                alpha: 0.12 + (pulseController.value * 0.08),
                              )
                            : color.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(borderRadius * 0.5),
                      ),
                      child: Icon(icon, size: 18, color: color),
                    );
                  },
                ),
                SizedBox(width: spacing),
                Text(
                  label,
                  style: textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
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
                _AutoScrollText(
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
                    fontFamily: 'monospace',
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
              ? _AutoScrollText(
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
                          fontFamily: 'monospace',
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
class _AutoScrollText extends StatefulWidget {
  final String text;
  final String? isp;
  final bool isProxyRunning;
  final ColorScheme colorScheme;
  final TextTheme textTheme;
  final bool isError;

  const _AutoScrollText({
    required this.text,
    this.isp,
    required this.isProxyRunning,
    required this.colorScheme,
    required this.textTheme,
    this.isError = false,
  });

  @override
  State<_AutoScrollText> createState() => _AutoScrollTextState();
}

class _AutoScrollTextState extends State<_AutoScrollText>
    with SingleTickerProviderStateMixin {
  late ScrollController _scrollController;
  late AnimationController _animationController;
  bool _needsScroll = false;
  double _maxScrollExtent = 0;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    );
    _animationController.addListener(_applyScrollOffset);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScrollNeeded();
    });

    AppLifecycle.instance.active.addListener(_syncAutoScroll);
  }

  void _checkScrollNeeded() {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollController.hasClients) {
        final maxExtent = _scrollController.position.maxScrollExtent;
        if (maxExtent > 0) {
          setState(() {
            _needsScroll = true;
            _maxScrollExtent = maxExtent;
          });
          _startAutoScroll();
        }
      }
    });
  }

  void _startAutoScroll() {
    if (!_needsScroll || !mounted) return;
    _syncAutoScroll();
  }

  /// Park the scroll offset for the current animation phase.
  ///
  /// Registered once from `initState`; it used to be added from
  /// `_startAutoScroll`, which can run more than once, so a rebuild could
  /// leave several copies racing to jump the same scroll controller.
  void _applyScrollOffset() {
    if (!mounted || !_scrollController.hasClients) return;

    final progress = _animationController.value;

    if (progress < 0.45) {
      _scrollController.jumpTo(_maxScrollExtent * (progress / 0.45));
    } else if (progress < 0.55) {
      _scrollController.jumpTo(_maxScrollExtent);
    } else {
      _scrollController.jumpTo(
        _maxScrollExtent * (1 - (progress - 0.55) / 0.45),
      );
    }
  }

  /// Run the marquee only while the text actually overflows and the app is on
  /// screen; otherwise leave the controller parked at rest.
  void _syncAutoScroll() {
    if (!mounted) return;
    final wanted = _needsScroll && AppLifecycle.instance.isActive;
    if (wanted) {
      if (!_animationController.isAnimating) {
        _animationController.repeat();
      }
    } else if (_animationController.isAnimating) {
      _animationController.stop();
    }
  }

  @override
  void didUpdateWidget(_AutoScrollText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) {
      _animationController.stop();
      _animationController.reset();
      _needsScroll = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkScrollNeeded();
      });
    }
  }

  @override
  void dispose() {
    AppLifecycle.instance.active.removeListener(_syncAutoScroll);
    _animationController.removeListener(_applyScrollOffset);
    _animationController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spacing = ResponsiveUtils.getSpacing(context);

    return SingleChildScrollView(
      controller: _scrollController,
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      child: Row(
        children: [
          Text(
            widget.text,
            style: widget.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
              color: widget.isError
                  ? widget.colorScheme.error
                  : widget.isProxyRunning
                  ? widget.colorScheme.primary
                  : widget.colorScheme.onSurface,
            ),
          ),
          if (widget.isp != null && widget.isp!.isNotEmpty) ...[
            SizedBox(width: spacing),
            Text(
              '(${widget.isp})',
              style: widget.textTheme.labelSmall?.copyWith(
                color: widget.colorScheme.onSurfaceVariant,
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _LegendDot(color: downloadColor, label: downloadLabel),
        const SizedBox(width: 12),
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
