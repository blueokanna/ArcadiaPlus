import 'dart:io';

import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/services/platform_proxy_service.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:arcadiaplus/src/utils/platform_utils.dart';

/// Owns the network-related switches and applies them to the platform.
///
/// [PlatformProxyService] is the authority on what the platform is doing; this
/// provider is what the screens read, and it mirrors that authority. Mirroring
/// is what makes a switch honest in the two situations that used to leave it
/// lying: when the app configures the platform itself (the system proxy on
/// service start, the tunnel on mobile) and when the platform changed under it
/// (the user flipped the setting in Windows, another VPN took the slot).
///
/// Every setter reports what actually happened: the platform proxy and the
/// tunnel are operated through [PlatformProxyService] and the live state is
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
    PlatformProxyService.instance.addListener(_mirrorPlatformState);
    _loadSettings();
  }

  @override
  void dispose() {
    PlatformProxyService.instance.removeListener(_mirrorPlatformState);
    super.dispose();
  }

  /// Re-reads both switches from the platform.
  ///
  /// Cheap enough to run whenever a screen showing them appears, and the only
  /// way a change made outside the app can reach the UI. Deliberately quiet —
  /// no loading flag, no notification unless a value actually moved — so it is
  /// safe to call from a screen's lifecycle callbacks.
  Future<void> refresh() async {
    final service = PlatformProxyService.instance;
    try {
      _applyLiveState(
        systemProxy: supportsSystemProxy
            ? await service.checkSystemProxyStatus()
            : false,
        tunEnabled: await service.checkTunModeStatus(),
      );
    } catch (e) {
      debugPrint('Failed to refresh network settings: $e');
    }
  }

  /// Adopts a state change the platform just made.
  void _mirrorPlatformState() {
    final service = PlatformProxyService.instance;
    _applyLiveState(
      systemProxy: supportsSystemProxy ? service.systemProxyEnabled : false,
      tunEnabled: service.tunModeEnabled,
    );
  }

  /// Writes the platform's own state into the settings and tells the UI about
  /// it, but only when a value actually moved.
  void _applyLiveState({required bool systemProxy, required bool tunEnabled}) {
    if (_settings.systemProxy == systemProxy &&
        _settings.tunEnabled == tunEnabled) {
      return;
    }
    _settings = _settings.copyWith(
      systemProxy: systemProxy,
      tunEnabled: tunEnabled,
    );
    notifyListeners();
  }

  Future<void> _loadSettings() async {
    _isLoading = true;
    notifyListeners();

    try {
      _settings = await StorageService.instance.getNetworkSettings();
      // The stored flags describe the last run; the platform is asked what it
      // is doing now. A restart must not leave a stale "on" behind — the
      // settings screen is reachable before the engine is ever started.
      await refresh();
    } catch (e) {
      debugPrint('Failed to load network settings: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// The bypass list belongs to the platform proxy configuration, so it only
  /// reaches the OS by writing the settings again.
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

    final service = PlatformProxyService.instance;
    if (value) {
      final applied = await _applySystemProxy();
      if (!applied) {
        throw StateError('The platform refused the proxy settings');
      }
    } else {
      final applied = await service.disableSystemProxy();
      if (!applied) {
        throw StateError('The platform refused to switch the proxy off');
      }
    }

    _settings = _settings.copyWith(
      systemProxy: await service.checkSystemProxyStatus(),
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

  /// Adds back any entry of [NetworkSettings.defaultBypassDomains] that is
  /// missing, keeping the user's own entries and their order.
  ///
  /// Additive on purpose: this is the "I deleted one by accident" path, and a
  /// reset that silently dropped someone's corporate domain would be worse
  /// than the mistake it repairs.
  Future<void> restoreDefaultBypassDomains() async {
    final domains = List<String>.of(_settings.bypassDomains);
    for (final entry in NetworkSettings.defaultBypassDomains) {
      if (!domains.contains(entry)) domains.add(entry);
    }
    if (domains.length == _settings.bypassDomains.length) return;
    await setBypassDomains(domains);
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
            ? (service.lastTunError ??
                  'The tunnel could not be started (privileges missing or '
                      'another VPN holds the slot)')
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
