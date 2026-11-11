import 'dart:async';

import 'package:flutter/foundation.dart';

import '../rust/api.dart' as api;
import '../rust/types.dart';
import '../utils/app_lifecycle.dart';
import 'native_core_service.dart';

typedef DnsActivitySnapshot = ({
  DnsQuerySnapshot queries,
  RecursiveDnsStatus status,
});
typedef DnsActivityReader = Future<DnsActivitySnapshot?> Function();

Future<DnsActivitySnapshot?> readDnsActivity() async {
  if (!NativeCoreService.instance.isReady) return null;
  final queries = api.getDnsQueryEvents();
  final status = api.getRecursiveDnsStatus();
  final values = await Future.wait<Object>([queries, status]);
  return (
    queries: values[0] as DnsQuerySnapshot,
    status: values[1] as RecursiveDnsStatus,
  );
}

/// Bounded snapshots only. Polling is scoped to a visible DNS panel, and pauses
/// with the application. Counts refer to retained events, not lifetime traffic.
class DnsActivityController extends ChangeNotifier {
  DnsActivityController({
    this.reader = readDnsActivity,
    this.clearer = api.clearDnsQueryEvents,
  }) {
    AppLifecycle.instance.active.addListener(_sync);
  }
  final DnsActivityReader reader;
  final Future<void> Function() clearer;
  List<DnsQueryEvent> records = const [];
  BigInt total = BigInt.zero;
  BigInt dropped = BigInt.zero;
  RecursiveDnsStatus? status;
  bool failed = false;
  bool loading = false;
  bool clearing = false;
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
    if (_disposed ||
        !_visible ||
        !AppLifecycle.instance.isActive ||
        loading ||
        clearing) {
      return;
    }
    final generation = _generation;
    loading = true;
    try {
      final value = await reader();
      if (_disposed || generation != _generation) return;
      records = List.unmodifiable(
        value?.queries.events.reversed.take(80) ?? const <DnsQueryEvent>[],
      );
      total = value?.queries.total ?? BigInt.zero;
      dropped = value?.queries.dropped ?? BigInt.zero;
      status = value?.status;
      failed = false;
    } catch (_) {
      if (!_disposed && generation == _generation) failed = true;
    } finally {
      loading = false;
      if (!_disposed && generation == _generation) notifyListeners();
    }
  }

  Future<void> clear() async {
    if (_disposed || clearing) return;
    _generation++;
    clearing = true;
    notifyListeners();
    try {
      await clearer();
      if (_disposed) return;
      records = const [];
      total = BigInt.zero;
      dropped = BigInt.zero;
      failed = false;
    } catch (_) {
      if (!_disposed) failed = true;
    } finally {
      clearing = false;
      if (!_disposed) notifyListeners();
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
