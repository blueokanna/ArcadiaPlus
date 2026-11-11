import 'package:flutter/foundation.dart';
import 'package:arcadiaplus/src/rust/api.dart' as rust_api;
import 'package:arcadiaplus/src/services/native_core_service.dart';
import 'package:arcadiaplus/src/utils/serial_task_queue.dart';

/// The node controller depends on this boundary, not on FFI initialization.
abstract interface class ProxyEngine implements Listenable {
  bool get isReady;
  bool supportsProfile(String? profileId);
  Future<T> transaction<T>(Future<T> Function(ProxyEngine engine) action);
  Future<bool> select(String group, String proxy);
  Future<String?> selected(String group);
  Future<int> measure(String proxy, String url);
}

class NativeProxyEngine implements ProxyEngine {
  const NativeProxyEngine();

  @override
  bool get isReady => NativeCoreService.instance.isReady;
  @override
  bool supportsProfile(String? profileId) => true;
  @override
  Future<T> transaction<T>(Future<T> Function(ProxyEngine engine) action) =>
      action(this);
  @override
  void addListener(VoidCallback listener) =>
      NativeCoreService.instance.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      NativeCoreService.instance.removeListener(listener);
  @override
  Future<bool> select(String group, String proxy) =>
      rust_api.selectProxyInGroup(groupName: group, proxyName: proxy);
  @override
  Future<String?> selected(String group) =>
      rust_api.getSelectedProxyInGroup(groupName: group);
  @override
  Future<int> measure(String proxy, String url) async =>
      (await rust_api.testProxyLatencyDto(
        tag: proxy,
        testUrl: url,
        timeoutMs: BigInt.from(5000),
      )).toInt();
}

/// Library availability and configured routing state have separate lifetimes.
/// Configuration replacement and selection transactions share one queue, so a
/// failed selection can never roll back into a newly installed configuration.
class ConfiguredProxyEngine extends ChangeNotifier implements ProxyEngine {
  ConfiguredProxyEngine(this._native);

  static final instance = ConfiguredProxyEngine(const NativeProxyEngine());
  final ProxyEngine _native;
  final _operations = SerialTaskQueue();
  bool _configured = false;
  String? _profileId;

  @override
  bool get isReady => _configured && _native.isReady;
  @override
  bool supportsProfile(String? profileId) => isReady && _profileId == profileId;

  Future<void> configure(
    String? profileId,
    Future<void> Function(ProxyEngine native) install,
  ) => _operations.run(() async {
    _configured = false;
    notifyListeners();
    try {
      await install(_native);
      _profileId = profileId;
      _configured = true;
    } finally {
      notifyListeners();
    }
  });

  Future<void> stop(Future<void> Function() shutdown) =>
      _operations.run(() async {
        _configured = false;
        notifyListeners();
        await shutdown();
      });

  @override
  Future<T> transaction<T>(Future<T> Function(ProxyEngine engine) action) =>
      _operations.run(() => action(this));

  void _requireReady() {
    if (!isReady) throw StateError('No configured proxy engine');
  }

  @override
  Future<bool> select(String group, String proxy) {
    _requireReady();
    return _native.select(group, proxy);
  }

  @override
  Future<String?> selected(String group) {
    _requireReady();
    return _native.selected(group);
  }

  @override
  Future<int> measure(String proxy, String url) {
    _requireReady();
    return _native.measure(proxy, url);
  }
}
