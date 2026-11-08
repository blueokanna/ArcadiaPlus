import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:arcadiaplus/src/services/proxy_engine_service.dart';

class FakeEngine extends ChangeNotifier implements ProxyEngine {
  @override
  bool isReady = false;
  bool get hasSubscribers => hasListeners;
  final selections = <String, String>{};
  final calls = <String>[];
  final measures = <String, Completer<int>>{};
  Completer<bool>? selectGate;
  bool reject = false;
  Future<bool> Function(String group, String proxy)? onSelect;
  Future<String?> Function(String group)? onSelected;
  int active = 0;
  int peak = 0;
  @override
  Future<bool> select(String group, String proxy) async {
    calls.add(proxy);
    if (onSelect != null) return onSelect!(group, proxy);
    final gate = selectGate;
    selectGate = null;
    if (gate != null && !await gate.future) return false;
    if (reject) return false;
    selections[group] = proxy;
    return true;
  }

  @override
  Future<String?> selected(String group) async =>
      onSelected != null ? await onSelected!(group) : selections[group];
  @override
  Future<int> measure(String proxy, String url) async {
    active++;
    if (active > peak) peak = active;
    try {
      return await measures.putIfAbsent(proxy, Completer<int>.new).future;
    } finally {
      active--;
    }
  }
}

String config([int count = 3]) {
  final nodes = List.generate(
    count,
    (i) => '  - {name: node$i, type: socks5, server: 127.0.0.1, port: 1080}',
  ).join('\n');
  final names = List.generate(count, (i) => 'node$i').join(',');
  return '''
proxies:
$nodes
proxy-groups:
  - name: route
    type: select
    proxies: [$names]
''';
}
