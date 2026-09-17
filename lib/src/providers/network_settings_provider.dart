import 'dart:io';
import 'package:flutter/material.dart';
import 'package:veloguard/src/services/platform_proxy_service.dart';
import 'package:veloguard/src/services/storage_service.dart';
import 'package:veloguard/src/utils/platform_utils.dart';

/// Owns the network-related switches and applies them to the platform.
///
/// Every setter reports what actually happened: the platform proxy and the
/// tunnel are operated through [PlatformProxyService] and their live state is
/// what gets stored, so a switch can never show "on" for a setting the OS
/// refused.
class NetworkSettingsProvider extends ChangeNotifier {
  NetworkSettings _settings = NetworkSettings();
  bool _isLoading = false;

  NetworkSettings get settings => _settings;
  bool get isLoading => _isLoading;

  // Convenience getters
  bool get systemProxy => _settings.systemProxy;
  List<String> get bypassDomains => _settings.bypassDomains;
  bool get tunEnabled => _settings.tunEnabled;

  /// Whether this platform has a system-wide proxy concept at all.
  bool get supportsSystemProxy =>
      !Platform.isAndroid && !Platform.isIOS && !PlatformUtils.isOHOS;

  NetworkSettingsProvider() {
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _isLoading = true;
    notifyListeners();

    try {
      _settings = await StorageService.instance.getNetworkSettings();
      // Both switches are process-scoped facts, not preferences: read what the
      // platform reports right now so a restart cannot leave a stale "on".
      final systemProxyLive = supportsSystemProxy
          ? await PlatformProxyService.instance.checkSystemProxyStatus()
          : false;
      final tunLive = await PlatformProxyService.instance.checkTunModeStatus();
      _settings = _settings.copyWith(
        systemProxy: systemProxyLive,
        tunEnabled: tunLive,
      );
    } catch (e) {
      debugPrint('Failed to load network settings: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _saveSettings() async {
    try {
      await StorageService.instance.saveNetworkSettings(_settings);
    } catch (e) {
      debugPrint('Failed to save network settings: $e');
    }
  }

  /// Enables or disables the platform's own proxy configuration.
  ///
  /// Throws when the platform rejects the change, so the caller can surface it
  /// instead of leaving a switch that lies about the system state.
  Future<void> setSystemProxy(bool value) async {
    if (!supportsSystemProxy) {
      throw UnsupportedError('This platform has no system proxy setting');
    }

    if (value) {
      final applied = await _applySystemProxy();
      if (!applied) {
        throw StateError('The platform refused the proxy settings');
      }
    } else {
      final applied = await PlatformProxyService.instance.disableSystemProxy();
      if (!applied) {
        throw StateError('The platform refused to restore the proxy settings');
      }
    }

    _settings = _settings.copyWith(
      systemProxy: await PlatformProxyService.instance.checkSystemProxyStatus(),
    );
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setBypassDomains(List<String> domains) async {
    _settings = _settings.copyWith(bypassDomains: domains);
    await _saveSettings();
    // The bypass list is part of the platform proxy configuration, so it only
    // reaches the OS by writing the settings again.
    if (_settings.systemProxy) {
      if (!await _applySystemProxy()) {
        debugPrint('Failed to re-apply the system proxy after a bypass change');
      }
    }
    notifyListeners();
  }

  Future<void> addBypassDomain(String domain) async {
    if (_settings.bypassDomains.contains(domain)) return;
    final newList = List<String>.from(_settings.bypassDomains)..add(domain);
    await setBypassDomains(newList);
  }

  Future<void> removeBypassDomain(String domain) async {
    final newList = List<String>.from(_settings.bypassDomains)..remove(domain);
    await setBypassDomains(newList);
  }

  /// Enables or disables the tunnel, in the mode the engine is currently in.
  ///
  /// Throws when the platform refuses, and stores the tunnel's own state.
  Future<void> setTunEnabled(bool value) async {
    final service = PlatformProxyService.instance;
    final applied = value
        ? await service.enableTunMode(
            mode: service.currentProxyMode,
            allowLan:
                (await StorageService.instance.getGeneralSettings()).allowLan,
          )
        : await service.disableTunMode();
    if (!applied) {
      throw StateError(
        value
            ? 'The tunnel could not be started (privileges missing or another '
                  'VPN holds the slot)'
            : 'The tunnel could not be stopped',
      );
    }

    _settings = _settings.copyWith(tunEnabled: service.tunModeEnabled);
    await _saveSettings();
    notifyListeners();
  }

  Future<bool> _applySystemProxy() async {
    final general = await StorageService.instance.getGeneralSettings();
    final host = general.bindAddress.contains(':') ? '::1' : '127.0.0.1';
    return PlatformProxyService.instance.enableSystemProxy(
      host: host,
      httpPort: general.mixedPort,
      bypass: _settings.bypassDomains,
    );
  }
}
