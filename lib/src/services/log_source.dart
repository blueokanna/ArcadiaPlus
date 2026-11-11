import 'package:arcadiaplus/src/rust/api.dart' as api;

import 'native_core_service.dart';
import 'service_diagnostics.dart';

abstract interface class LogSource {
  Future<List<String>> read();
  Future<void> clear();
}

class NativeLogSource implements LogSource {
  const NativeLogSource();

  void _checkReady() {
    if (!NativeCoreService.instance.isReady) {
      throw StateError('Native core is not ready');
    }
  }

  @override
  Future<List<String>> read() async {
    if (!NativeCoreService.instance.isReady &&
        ServiceDiagnostics.entries.isNotEmpty) {
      return ServiceDiagnostics.entries;
    }
    _checkReady();
    final entries = [
      ...await api.getLogs(lines: 1000),
      ...ServiceDiagnostics.entries,
    ]..sort();
    return entries.length > 1000
        ? entries.sublist(entries.length - 1000)
        : entries;
  }

  @override
  Future<void> clear() async {
    if (NativeCoreService.instance.isReady) await api.clearLogs();
    ServiceDiagnostics.clear();
  }
}
