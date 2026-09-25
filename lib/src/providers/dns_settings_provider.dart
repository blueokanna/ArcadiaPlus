import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';

/// Owns the DNS settings that the engine can actually carry.
class DnsSettingsProvider extends ChangeNotifier {
  /// Every mode the engine accepts, in the order the picker shows them.
  ///
  /// Re-exported from the model so the settings screen does not have to import
  /// the store just to list its options.
  static const List<String> modes = DnsSettings.modes;

  DnsSettings _settings = DnsSettings();
  bool _isLoading = false;

  DnsSettings get settings => _settings;
  bool get isLoading => _isLoading;

  // Convenience getters
  bool get enable => _settings.enable;
  bool get overrideDns => _settings.overrideDns;
  String get listen => _settings.listen;
  bool get useRecursiveResolver => _settings.useRecursiveResolver;
  String get dnsMode => _settings.dnsMode;
  List<String> get nameservers => _settings.nameservers;
  List<String> get fallback => _settings.fallback;

  DnsSettingsProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _isLoading = true;
    notifyListeners();

    try {
      _settings = await StorageService.instance.getDnsSettings();
    } catch (e) {
      debugPrint('Failed to load DNS settings: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _saveSettings() async {
    try {
      await StorageService.instance.saveDnsSettings(_settings);
    } catch (e) {
      debugPrint('Failed to save DNS settings: $e');
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
    await _update((s) => s.copyWith(useRecursiveResolver: value));
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
    final additions = <String>[];
    for (final server in servers) {
      final trimmed = server.trim();
      if (trimmed.isEmpty) continue;
      if (_settings.nameservers.contains(trimmed)) continue;
      if (additions.contains(trimmed)) continue;
      additions.add(trimmed);
    }
    if (additions.isEmpty) return;
    await setNameservers([..._settings.nameservers, ...additions]);
  }

  Future<void> removeNameserver(String server) async {
    if (!_settings.nameservers.contains(server)) return;
    await setNameservers(
      _settings.nameservers.where((entry) => entry != server).toList(),
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
    final additions = <String>[];
    for (final server in servers) {
      final trimmed = server.trim();
      if (trimmed.isEmpty) continue;
      if (_settings.fallback.contains(trimmed)) continue;
      if (additions.contains(trimmed)) continue;
      additions.add(trimmed);
    }
    if (additions.isEmpty) return;
    await setFallback([..._settings.fallback, ...additions]);
  }

  Future<void> removeFallback(String server) async {
    if (!_settings.fallback.contains(server)) return;
    await setFallback(
      _settings.fallback.where((entry) => entry != server).toList(),
    );
  }

  /// Applies [change] and persists it, but only when it produces a different
  /// record.
  ///
  /// A provider that notifies on every write rebuilds every `Consumer` that
  /// watches it — here, the whole settings list — even when the user re-picked
  /// the value that was already selected.
  Future<void> _update(DnsSettings Function(DnsSettings current) change) async {
    final next = change(_settings);
    if (_sameAs(next)) return;
    _settings = next;
    await _saveSettings();
    notifyListeners();
  }

  bool _sameAs(DnsSettings other) {
    final current = _settings;
    return current.enable == other.enable &&
        current.overrideDns == other.overrideDns &&
        current.listen == other.listen &&
        current.useRecursiveResolver == other.useRecursiveResolver &&
        current.dnsMode == other.dnsMode &&
        current.nameserversRevision == other.nameserversRevision &&
        listEquals(current.nameservers, other.nameservers) &&
        listEquals(current.fallback, other.fallback);
  }
}
