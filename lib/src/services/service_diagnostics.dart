/// Startup failures can occur before the native logger exists. Keep a bounded
/// process-local history so the logs screen includes the cause of a rollback.
abstract final class ServiceDiagnostics {
  static final _entries = <String>[];
  static List<String> get entries => List.unmodifiable(_entries);

  static void failure(String detail) =>
      _record('ERROR', 'Service startup', detail);

  static void warning(String detail) => _record('WARN', 'DNS', detail);

  static void _record(String level, String source, String detail) {
    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .substring(0, 19)
        .replaceAll('T', ' ');
    final message = detail.replaceAll(RegExp(r'[\r\n]+'), ' ');
    _entries.add(
      '[$timestamp] [$level] $source: ${message.length > 2048 ? message.substring(0, 2048) : message}',
    );
    if (_entries.length > 32) _entries.removeAt(0);
  }

  static void clear() => _entries.clear();
}
