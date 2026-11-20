import 'dart:async';
import 'dart:convert';
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
  ExitIpController({this.clientFactory, DateTime Function()? now})
    : _now = now ?? DateTime.now {
    AppLifecycle.instance.active.addListener(_lifecycle);
    _subscription = ProxySelectionEvents.changes.listen(
      (_) => configure(
        useProxy: _proxy,
        port: _port,
        listener: _listener,
        active: _visible,
        invalidate: true,
      ),
    );
  }
  final IpProbeClientFactory? clientFactory;
  final DateTime Function() _now;
  static const cacheLifetime = Duration(hours: 1);
  DateTime? _lastAttempt;
  ProbeListener? _listener;
  StreamSubscription<String>? _subscription;
  Dio? _client;
  Timer? _debounce;
  Timer? _retry;
  bool _disposed = false;
  bool _proxy = false;
  bool _active = false;
  bool _visible = false;
  int _port = 7890;
  int _generation = 0;
  ExitIpReport? ipv4;
  ExitIpReport? ipv6;
  ExitIpReport? get report => ipv4 ?? ipv6;
  bool loading = false;
  bool failed = false;

  void _lifecycle() => configure(
    useProxy: _proxy,
    port: _port,
    listener: _listener,
    active: _visible,
  );

  void hide() => configure(
    useProxy: _proxy,
    port: _port,
    listener: _listener,
    active: false,
  );

  void configure({
    required bool useProxy,
    required int port,
    ProbeListener? listener,
    required bool active,
    bool invalidate = false,
  }) {
    if (_disposed) return;
    _visible = active;
    active = active && AppLifecycle.instance.isActive;
    final changed =
        _proxy != useProxy ||
        _port != port ||
        _listener != listener ||
        invalidate;
    final resumed = !_active && active;
    _proxy = useProxy;
    _port = port;
    _listener = listener;
    _active = active;
    if (changed || !active) {
      _generation++;
      _client?.close(force: true);
      _client = null;
      _debounce?.cancel();
      _retry?.cancel();
      loading = false;
      if (changed) {
        ipv4 = null;
        ipv6 = null;
        failed = false;
        _lastAttempt = null;
      }
    }
    if (active &&
        !loading &&
        !(_debounce?.isActive ?? false) &&
        (_lastAttempt == null ||
            _now().isBefore(_lastAttempt!) ||
            _now().difference(_lastAttempt!) >=
                (failed ? const Duration(seconds: 30) : cacheLifetime))) {
      _debounce?.cancel();
      _debounce = Timer(
        resumed ? Duration.zero : const Duration(milliseconds: 350),
        refresh,
      );
    }
    if (resumed && failed && !(_debounce?.isActive ?? false)) {
      _retry = Timer(const Duration(seconds: 30), refresh);
    }
  }

  Future<void> refresh() async {
    if (_disposed || !_active || loading) return;
    _retry?.cancel();
    final generation = ++_generation;
    bool current() => !_disposed && _active && generation == _generation;
    loading = true;
    failed = false;
    notifyListeners();
    final client =
        clientFactory?.call(_proxy, _port) ??
        createIpProbeClient(_proxy, _port, listener: _listener);
    _client = client;
    var foundV4 = false;
    var foundV6 = false;
    Future<void> probe(
      InternetAddressType family,
      List<(String, String)> sources,
    ) async {
      for (final (url, source) in sources) {
        if (!current()) return;
        try {
          final response = await client.get<Object?>(
            url,
            options: Options(
              followRedirects: false,
              responseType: ResponseType.json,
            ),
          );
          if (response.statusCode != 200) continue;
          final body = response.data;
          final data = body is String ? jsonDecode(body) : body;
          if (data is! Map<String, dynamic>) continue;
          final next = ExitIpReport.parse(data, source: source);
          if (!current()) return;
          final type = InternetAddress(next.ip).type;
          if (type == InternetAddressType.IPv6) {
            ipv6 = next;
            foundV6 = true;
          } else if (family == InternetAddressType.IPv4) {
            ipv4 = next;
            foundV4 = true;
          }
          notifyListeners();
          if (family == type) return;
        } catch (_) {
          // The location fallback never inherits another provider's risk flags.
        }
      }
    }

    try {
      await Future.wait([
        probe(InternetAddressType.IPv4, [
          ('https://api.ipquery.io/?format=json', 'IPQuery'),
          ('https://api.ipify.org?format=json', 'ipify'),
          ('https://api-ipv4.ip.sb/geoip', 'IP.SB'),
        ]),
        probe(InternetAddressType.IPv6, [
          ('https://api-ipv6.ip.sb/geoip', 'IP.SB'),
          ('https://api6.ipify.org?format=json', 'ipify'),
        ]),
      ]);
      if (current()) {
        if (!foundV4) ipv4 = null;
        if (!foundV6) ipv6 = null;
        failed = report == null;
        _lastAttempt = _now();
        if (failed) _retry = Timer(const Duration(seconds: 30), refresh);
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
    _retry?.cancel();
    _subscription?.cancel();
    _client?.close(force: true);
    super.dispose();
  }
}
