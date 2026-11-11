import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rust/api.dart' as api;
import '../rust/types.dart';
import '../utils/app_lifecycle.dart';
import 'native_core_service.dart';

class DnsQueryObservation {
  const DnsQueryObservation({
    required this.time,
    required this.domain,
    required this.type,
  });
  final String time;
  final String domain;
  final String type;

  // This is the actual Corduit TUN ingress event, not an inferred TCP hostname.
  static final _event = RegExp(
    r'^\[([^\]]+)\] \[INFO\] DNS query received: ([^\s]+) \((A|AAAA|[A-Za-z0-9_]+)\)$',
  );
  static DnsQueryObservation? parse(String line) {
    final match = _event.firstMatch(line);
    if (match == null || match[2]!.length > 254) return null;
    return DnsQueryObservation(
      time: match[1]!,
      domain: match[2]!,
      type: match[3]!,
    );
  }
}

typedef DnsActivitySnapshot = ({List<String> logs, RecursiveDnsStatus status});
typedef DnsActivityReader = Future<DnsActivitySnapshot?> Function();

Future<DnsActivitySnapshot?> readDnsActivity() async {
  if (!NativeCoreService.instance.isReady) return null;
  final logs = api.getLogs(lines: 500);
  final status = api.getRecursiveDnsStatus();
  final values = await Future.wait<Object>([logs, status]);
  return (
    logs: values[0] as List<String>,
    status: values[1] as RecursiveDnsStatus,
  );
}

/// Bounded snapshots only. Polling is scoped to a visible DNS panel, and pauses
/// with the application. Counts refer to retained events, not lifetime traffic.
class DnsActivityController extends ChangeNotifier {
  DnsActivityController({this.reader = readDnsActivity}) {
    AppLifecycle.instance.active.addListener(_sync);
  }
  final DnsActivityReader reader;
  List<DnsQueryObservation> records = const [];
  RecursiveDnsStatus? status;
  bool failed = false;
  bool loading = false;
  bool _visible = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? _timer;

  void setVisible(bool value) {
    if (_visible == value) return;
    _visible = value;
    _sync();
  }

  void _sync() {
    _generation++;
    _timer?.cancel();
    if (_visible && AppLifecycle.instance.isActive && !_disposed) {
      // Defer notification until the caller's current build has completed.
      _timer = Timer(Duration.zero, () {
        refresh();
        _timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
      });
    }
  }

  Future<void> refresh() async {
    if (_disposed || !_visible || !AppLifecycle.instance.isActive || loading) {
      return;
    }
    final generation = _generation;
    loading = true;
    try {
      final value = await reader();
      if (_disposed || generation != _generation) return;
      final parsed =
          value?.logs
              .map(DnsQueryObservation.parse)
              .whereType<DnsQueryObservation>()
              .toList() ??
          [];
      records = List.unmodifiable(parsed.reversed.take(80));
      status = value?.status;
      failed = false;
    } catch (_) {
      if (!_disposed && generation == _generation) failed = true;
    } finally {
      loading = false;
      if (!_disposed && generation == _generation) notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    AppLifecycle.instance.active.removeListener(_sync);
    super.dispose();
  }
}
