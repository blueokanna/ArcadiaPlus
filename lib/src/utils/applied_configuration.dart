import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Remembers config identity without keeping a second routing document alive.
/// HarmonyOS alone needs the source for its separate extension and rollback.
final class AppliedConfiguration {
  AppliedConfiguration(String source, {bool retainSource = false})
    : _fingerprint = fingerprint(source),
      retainedSource = retainSource ? source : null;

  final String _fingerprint;
  final String? retainedSource;

  bool matches(String candidate) => _fingerprint == fingerprint(candidate);

  static String fingerprint(String source) =>
      sha256.convert(utf8.encode(source)).toString();
}
