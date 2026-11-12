import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'ip_probe_client.dart';
import 'proxy_selection_events.dart';
import '../utils/app_lifecycle.dart';

enum IpNetworkKind { residentialCandidate, mobile, hosting, proxy, unknown }

/// A provider assessment, not a claim about the owner of an IP address.
class ExitIpReport {
  const ExitIpReport({
    required this.ip,
    required this.source,
    required this.checkedAt,
    this.organization,
    this.countryCode,
    this.network = IpNetworkKind.unknown,
    this.riskScore,
  });
  final String ip;
  final String source;
  final DateTime checkedAt;
  final String? organization;
  final String? countryCode;
  final IpNetworkKind network;
  final int? riskScore;

  factory ExitIpReport.parse(
    Map<String, dynamic> data, {
    required String source,
  }) {
    final ip = data['ip'];
    if (ip is! String || InternetAddress.tryParse(ip) == null) {
      throw const FormatException('Invalid exit IP response');
    }
    final risk = data['risk'] is Map ? data['risk'] as Map : const {};
    final isp = data['isp'] is Map ? data['isp'] as Map : const {};
    final location = data['location'] is Map ? data['location'] as Map : data;
    final complete = [
      'is_mobile',
      'is_vpn',
      'is_proxy',
      'is_tor',
      'is_datacenter',
    ].every((key) => risk[key] is bool);
    final kind = risk['is_datacenter'] == true
        ? IpNetworkKind.hosting
        : risk['is_vpn'] == true ||
              risk['is_proxy'] == true ||
              risk['is_tor'] == true
        ? IpNetworkKind.proxy
        : risk['is_mobile'] == true
        ? IpNetworkKind.mobile
        : complete
        ? IpNetworkKind.residentialCandidate
        : IpNetworkKind.unknown;
    final score = risk['risk_score'];
    String? text(Object? value) => value is String && value.trim().isNotEmpty
        ? value.trim().substring(0, value.trim().length.clamp(0, 200))
        : null;
    return ExitIpReport(
      ip: ip,
      source: source,
      checkedAt: DateTime.now(),
      organization:
          text(isp['org']) ?? text(data['organization']) ?? text(data['isp']),
      countryCode: text(location['country_code']),
      network: kind,
      riskScore: score is num && score.isFinite && score >= 0 && score <= 100
          ? score.toInt()
          : null,
    );
  }
}

/// Owns one lookup. Route changes cancel sockets and invalidate late replies.
/// No API secrets, disk history or direct fallback while the proxy is selected.
class ExitIpController extends ChangeNotifier {
  ExitIpController({
    this.clientFactory = createIpProbeClient,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    AppLifecycle.instance.active.addListener(_lifecycle);
    _subscription = ProxySelectionEvents.changes.listen(
      (_) => configure(
        useProxy: _proxy,
        port: _port,
        active: _visible,
        invalidate: true,
      ),
    );
  }
  final IpProbeClientFactory clientFactory;
  final DateTime Function() _now;
  static const cacheLifetime = Duration(hours: 1);
  DateTime? _lastAttempt;
  bool get requested => _visible;
  StreamSubscription<String>? _subscription;
  Dio? _client;
  Timer? _debounce;
  bool _disposed = false;
  bool _proxy = false;
  bool _active = false;
  bool _visible = false;
  int _port = 7890;
  int _generation = 0;
  ExitIpReport? report;
  bool loading = false;
  bool failed = false;

  void _lifecycle() =>
      configure(useProxy: _proxy, port: _port, active: _visible);

  void configure({
    required bool useProxy,
    required int port,
    required bool active,
    bool invalidate = false,
  }) {
    if (_disposed) return;
    _visible = active;
    active = active && AppLifecycle.instance.isActive;
    final changed = _proxy != useProxy || _port != port || invalidate;
    final resumed = !_active && active;
    _proxy = useProxy;
    _port = port;
    _active = active;
    if (changed || !active) {
      _generation++;
      _client?.close(force: true);
      _client = null;
      _debounce?.cancel();
      loading = false;
      if (changed) {
        report = null;
        failed = false;
        _lastAttempt = null;
      }
    }
    if (active &&
        !loading &&
        !(_debounce?.isActive ?? false) &&
        (_lastAttempt == null ||
            _now().isBefore(_lastAttempt!) ||
            _now().difference(_lastAttempt!) >= cacheLifetime)) {
      _debounce?.cancel();
      _debounce = Timer(
        resumed ? Duration.zero : const Duration(milliseconds: 350),
        refresh,
      );
    }
  }

  Future<void> refresh() async {
    if (_disposed || !_active || loading) return;
    final generation = ++_generation;
    bool current() => !_disposed && _active && generation == _generation;
    loading = true;
    failed = false;
    notifyListeners();
    final client = clientFactory(_proxy, _port);
    _client = client;
    try {
      ExitIpReport? next;
      for (final (url, source) in [
        ('https://api.ipquery.io/?format=json', 'IPQuery'),
        ('https://api.ip.sb/geoip', 'IP.SB'),
      ]) {
        if (!current()) return;
        try {
          final response = await client.get<Object?>(
            url,
            options: Options(
              followRedirects: false,
              responseType: ResponseType.json,
            ),
          );
          if (response.statusCode != 200 ||
              response.data is! Map<String, dynamic>) {
            continue;
          }
          next = ExitIpReport.parse(
            response.data as Map<String, dynamic>,
            source: source,
          );
          break;
        } catch (_) {
          // The location fallback never inherits another provider's risk flags.
        }
      }
      if (current()) {
        report = next;
        failed = next == null;
        // Cache completed failures too. Revisiting a page must not repeatedly
        // contact an unavailable provider; the refresh button remains explicit.
        _lastAttempt = _now();
      }
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
      if (current()) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    AppLifecycle.instance.active.removeListener(_lifecycle);
    _disposed = true;
    _generation++;
    _debounce?.cancel();
    _subscription?.cancel();
    _client?.close(force: true);
    super.dispose();
  }
}
