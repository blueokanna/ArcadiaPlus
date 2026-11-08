import 'package:flutter/foundation.dart';
import 'package:arcadiaplus/src/rust/api.dart' as rust_api;
import 'package:arcadiaplus/src/services/native_core_service.dart';

/// The node controller depends on this boundary, not on FFI initialization.
abstract interface class ProxyEngine implements Listenable {
  bool get isReady;
  Future<bool> select(String group, String proxy);
  Future<String?> selected(String group);
  Future<int> measure(String proxy, String url);
}

class NativeProxyEngine implements ProxyEngine {
  const NativeProxyEngine();

  @override
  bool get isReady => NativeCoreService.instance.isReady;
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
