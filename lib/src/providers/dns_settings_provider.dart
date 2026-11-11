import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:arcadiaplus/src/utils/serial_task_queue.dart';

/// Owns the DNS settings that the engine can actually carry.
class DnsSettingsProvider extends ChangeNotifier {
  /// Every mode the engine accepts, in the order the picker shows them.
  ///
  /// Re-exported from the model so the settings screen does not have to import
  /// the store just to list its options.
  static const List<String> modes = DnsSettings.modes;

  DnsSettings _settings = DnsSettings();
  bool _isLoading = false;
  bool _disposed = false;
  String? _saveError;
  final _writes = SerialTaskQueue();
  late final Future<void> _loaded;
  final Future<DnsSettings> Function() _read;
  final Future<void> Function(DnsSettings) _write;

  DnsSettings get settings => _settings;
  bool get isLoading => _isLoading;
  String? get saveError => _saveError;

  // Convenience getters
  bool get enable => _settings.enable;
  bool get overrideDns => _settings.overrideDns;
  String get listen => _settings.listen;
  bool get useRecursiveResolver =>
      _settings.useRecursiveResolver && !_settings.requireEncryptedDns;
  bool get requireEncryptedDns => _settings.requireEncryptedDns;

  Future<void> setRequireEncryptedDns(bool value) => _update(
    (s) => s.copyWith(
      requireEncryptedDns: value,
      useRecursiveResolver: value ? false : s.useRecursiveResolver,
    ),
  );
  String get dnsMode => _settings.dnsMode;
  List<String> get nameservers => _settings.nameservers;
  List<String> get fallback => _settings.fallback;
  List<String> get bootstrap => _settings.bootstrap;

  DnsSettingsProvider({
    Future<DnsSettings> Function()? read,
    Future<void> Function(DnsSettings)? write,
  }) : _read = read ?? StorageService.instance.getDnsSettings,
       _write = write ?? StorageService.instance.saveDnsSettings {
    _loaded = _loadSettings();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _loadSettings() async {
    _isLoading = true;
    notifyListeners();

    try {
      _settings = await _read();
    } catch (e) {
      debugPrint('Failed to load DNS settings: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> setEnable(bool value) async {
    await _update((s) => s.copyWith(enable: value));
  }

  /// Whether this app's DNS section replaces the profile's on the next start.
  Future<void> setOverrideDns(bool value) async {
    await _update((s) => s.copyWith(overrideDns: value));
  }

  Future<void> setListen(String value) async {
    await _update((s) => s.copyWith(listen: value));
  }

  /// Starts or stops the RecurseX front-end on the next start.
  Future<void> setUseRecursiveResolver(bool value) async {
    await _update((s) {
      if (value && s.requireEncryptedDns) {
        throw StateError(
          'Disable encrypted DNS protection before enabling root recursion.',
        );
      }
      return s.copyWith(useRecursiveResolver: value);
    });
  }

  /// `normal`, `redir-host` or `fake-ip`; anything else is refused rather than
  /// stored, because the engine would not know what to do with it.
  Future<void> setDnsMode(String value) async {
    if (!modes.contains(value)) {
      debugPrint('Unsupported DNS mode: $value');
      return;
    }
    await _update((s) => s.copyWith(dnsMode: value));
  }

  Future<void> setNameservers(List<String> value) async {
    await _update((s) => s.copyWith(nameservers: List.unmodifiable(value)));
  }

  Future<void> addNameserver(String server) => addNameservers([server]);

  /// Adds every entry of [servers] that is not already in the list.
  ///
  /// The presets in the editor are added in one call, so a single save and a
  /// single notification cover a whole batch — and the list is only replaced
  /// when something was actually missing.
  Future<void> addNameservers(Iterable<String> servers) async {
    final additions = servers.toList(growable: false);
    await _update(
      (s) => s.copyWith(nameservers: _merge(s.nameservers, additions)),
    );
  }

  Future<void> removeNameserver(String server) async {
    await _update(
      (s) => s.copyWith(nameservers: _without(s.nameservers, server)),
    );
  }

  Future<void> setFallback(List<String> value) async {
    await _update((s) => s.copyWith(fallback: List.unmodifiable(value)));
  }

  Future<void> addFallback(String server) => addFallbacks([server]);

  /// Adds every entry of [servers] that is not already in the fallback list,
  /// in one write and one notification, for the same reason as
  /// [addNameservers].
  Future<void> addFallbacks(Iterable<String> servers) async {
    final additions = servers.toList(growable: false);
    await _update((s) => s.copyWith(fallback: _merge(s.fallback, additions)));
  }

  Future<void> removeFallback(String server) async {
    await _update((s) => s.copyWith(fallback: _without(s.fallback, server)));
  }

  Future<void> setBootstrap(List<String> value) async {
    await _update((s) => s.copyWith(bootstrap: List.unmodifiable(value)));
  }

  /// Adds every entry of [servers] that is not already in the bootstrap list.
  Future<void> addBootstrap(Iterable<String> servers) async {
    final additions = servers.toList(growable: false);
    await _update((s) => s.copyWith(bootstrap: _merge(s.bootstrap, additions)));
  }

  Future<void> removeBootstrap(String server) async {
    await _update((s) => s.copyWith(bootstrap: _without(s.bootstrap, server)));
  }

  static List<String> _merge(
    List<String> current,
    Iterable<String> additions,
  ) => List.unmodifiable({
    ...current,
    ...additions.map((s) => s.trim()).where((s) => s.isNotEmpty),
  });

  static List<String> _without(List<String> current, String server) =>
      List.unmodifiable(current.where((entry) => entry != server));

  /// Applies [change] and persists it, but only when it produces a different
  /// record.
  ///
  /// A provider that notifies on every write rebuilds every `Consumer` that
  /// watches it — here, the whole settings list — even when the user re-picked
  /// the value that was already selected.
  Future<void> _update(DnsSettings Function(DnsSettings current) change) =>
      _writes.run(() async {
        await _loaded;
        try {
          final next = change(_settings);
          if (_sameAs(next)) return;
          await _write(next);
          _settings = next;
          _saveError = null;
        } catch (error) {
          _saveError = error.toString();
        }
        notifyListeners();
      });

  bool _sameAs(DnsSettings other) {
    final current = _settings;
    return current.enable == other.enable &&
        current.overrideDns == other.overrideDns &&
        current.listen == other.listen &&
        current.useRecursiveResolver == other.useRecursiveResolver &&
        current.requireEncryptedDns == other.requireEncryptedDns &&
        current.dnsMode == other.dnsMode &&
        current.nameserversRevision == other.nameserversRevision &&
        listEquals(current.nameservers, other.nameservers) &&
        listEquals(current.fallback, other.fallback) &&
        listEquals(current.bootstrap, other.bootstrap);
  }
}
