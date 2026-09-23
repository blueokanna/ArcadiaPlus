import 'package:flutter/material.dart';
import 'package:arcadia_plus/src/services/storage_service.dart';

/// Owns the DNS settings that the engine can actually carry.
class DnsSettingsProvider extends ChangeNotifier {
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
    _settings = _settings.copyWith(enable: value);
    await _saveSettings();
    notifyListeners();
  }

  /// Whether this app's DNS section replaces the profile's on the next start.
  Future<void> setOverrideDns(bool value) async {
    _settings = _settings.copyWith(overrideDns: value);
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setListen(String value) async {
    _settings = _settings.copyWith(listen: value);
    await _saveSettings();
    notifyListeners();
  }

  /// Starts or stops the RecurseX front-end on the next start.
  Future<void> setUseRecursiveResolver(bool value) async {
    _settings = _settings.copyWith(useRecursiveResolver: value);
    await _saveSettings();
    notifyListeners();
  }

  /// `normal` or `fake-ip`; anything else is refused rather than stored.
  Future<void> setDnsMode(String value) async {
    if (value != 'normal' && value != 'fake-ip') {
      debugPrint('Unsupported DNS mode: $value');
      return;
    }
    _settings = _settings.copyWith(dnsMode: value);
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setNameservers(List<String> value) async {
    _settings = _settings.copyWith(nameservers: value);
    await _saveSettings();
    notifyListeners();
  }

  Future<void> addNameserver(String server) async {
    final trimmed = server.trim();
    if (trimmed.isEmpty || _settings.nameservers.contains(trimmed)) return;
    await setNameservers([..._settings.nameservers, trimmed]);
  }

  Future<void> removeNameserver(String server) async {
    await setNameservers(
      _settings.nameservers.where((entry) => entry != server).toList(),
    );
  }

  Future<void> setFallback(List<String> value) async {
    _settings = _settings.copyWith(fallback: value);
    await _saveSettings();
    notifyListeners();
  }

  Future<void> addFallback(String server) async {
    final trimmed = server.trim();
    if (trimmed.isEmpty || _settings.fallback.contains(trimmed)) return;
    await setFallback([..._settings.fallback, trimmed]);
  }

  Future<void> removeFallback(String server) async {
    await setFallback(
      _settings.fallback.where((entry) => entry != server).toList(),
    );
  }
}
