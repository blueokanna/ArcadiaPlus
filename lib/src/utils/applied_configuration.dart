import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../services/ip_probe_client.dart';

/// Remembers config identity without keeping a second routing document alive.
/// HarmonyOS alone needs the source for its separate extension and rollback.
final class AppliedConfiguration {
  AppliedConfiguration(String source, {bool retainSource = false})
    : _fingerprint = fingerprint(source),
      retainedSource = retainSource ? source : null,
      probeListener = _listener(jsonDecode(source));

  final String _fingerprint;
  final String? retainedSource;
  final ProbeListener? probeListener;

  static ProbeListener? _listener(Map config) {
    final inbounds = (config['inbounds'] as List? ?? const []).whereType<Map>();
    final auth = (config['general']?['authentication'] as List?)
        ?.whereType<Map>()
        .firstOrNull;
    for (final kind in ['mixed', 'http']) {
      for (final inbound in inbounds) {
        if ((inbound['inbound_type'] ?? inbound['type']) == kind &&
            inbound['port'] is int &&
            inbound['port'] > 0) {
          return (
            host: inbound['listen'] as String? ?? '127.0.0.1',
            port: inbound['port'] as int,
            user: auth?['username'] as String?,
            password: auth?['password'] as String?,
          );
        }
      }
    }
    return null;
  }

  bool matches(String candidate) => _fingerprint == fingerprint(candidate);

  static String fingerprint(String source) =>
      sha256.convert(utf8.encode(source)).toString();
}
