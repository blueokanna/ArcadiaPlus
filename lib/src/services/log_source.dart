import 'package:arcadiaplus/src/rust/api.dart' as api;

import 'native_core_service.dart';

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
  Future<List<String>> read() {
    _checkReady();
    return api.getLogs(lines: 1000);
  }

  @override
  Future<void> clear() {
    _checkReady();
    return api.clearLogs();
  }
}
