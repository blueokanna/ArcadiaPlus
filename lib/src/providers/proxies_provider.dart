import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:arcadiaplus/src/services/config_converter.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:arcadiaplus/src/rust/api.dart' as rust_api;
import 'package:arcadiaplus/src/services/native_core_service.dart';

/// Latency test result
class LatencyResult {
  final String proxyName;
  final int? latencyMs;
  final bool isSuccess;
  final String? error;

  LatencyResult({
    required this.proxyName,
    this.latencyMs,
    this.isSuccess = false,
    this.error,
  });
}

/// Stream controller for proxy selection changes
final proxySelectionChangedController = StreamController<String>.broadcast();

class ProxiesProvider extends ChangeNotifier {
  ParsedClashConfig? _config;
  String? _selectedGroupName;
  final Map<String, String> _selectedProxies = {};
  final Map<String, LatencyResult> _latencyResults = {};
  bool _isLoading = false;
  bool _isTesting = false;
  String? _error;
  bool _rustSyncPending = false;
  bool _engineReadyListenerAttached = false;

  ParsedClashConfig? get config => _config;
  String? get selectedGroupName => _selectedGroupName;
  Map<String, String> get selectedProxies => _selectedProxies;
  Map<String, LatencyResult> get latencyResults => _latencyResults;
  bool get isLoading => _isLoading;
  bool get isTesting => _isTesting;
  String? get error => _error;

  List<ParsedProxyGroup> get proxyGroups => _config?.proxyGroups ?? [];
  List<ParsedProxy> get proxies => _config?.proxies ?? [];

  /// Get the currently selected group
  ParsedProxyGroup? get selectedGroup {
    if (_selectedGroupName == null || _config == null) return null;
    try {
      return _config!.proxyGroups.firstWhere(
        (g) => g.name == _selectedGroupName,
      );
    } catch (e) {
      return _config!.proxyGroups.isNotEmpty
          ? _config!.proxyGroups.first
          : null;
    }
  }

  /// Get proxies for a specific group
  List<dynamic> getProxiesForGroup(ParsedProxyGroup group) {
    final result = <dynamic>[];
    for (final proxyName in group.proxies) {
      // Check if it's a direct/reject
      if (proxyName == 'DIRECT' || proxyName == 'REJECT') {
        result.add(proxyName);
        continue;
      }
      // Check if it's another group
      final subGroup = _config?.proxyGroups
          .where((g) => g.name == proxyName)
          .firstOrNull;
      if (subGroup != null) {
        result.add(subGroup);
        continue;
      }
      // Check if it's a proxy
      final proxy = _config?.proxies
          .where((p) => p.name == proxyName)
          .firstOrNull;
      if (proxy != null) {
        result.add(proxy);
      } else {
        // Unknown proxy, add as string
        result.add(proxyName);
      }
    }
    return result;
  }

  /// Load config from the active profile
  Future<void> loadFromActiveProfile() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final activeProfileId = await StorageService.instance
          .getActiveProfileId();
      if (activeProfileId == null) {
        _config = null;
        _error = 'No active profile';
        return;
      }

      final configContent = await StorageService.instance.getProfileConfig(
        activeProfileId,
      );
      if (configContent == null) {
        _config = null;
        _error = 'Profile config not found';
        return;
      }

      _config = ConfigConverter.parseClashConfig(configContent);

      // Load persisted selections
      await _loadPersistedSelections();

      // Select first group by default if no persisted selection
      if (_config!.proxyGroups.isNotEmpty && _selectedGroupName == null) {
        _selectedGroupName = _config!.proxyGroups.first.name;
      }

      // Initialize selected proxies with first proxy in each group if not persisted
      for (final group in _config!.proxyGroups) {
        if (!_selectedProxies.containsKey(group.name) &&
            group.proxies.isNotEmpty) {
          _selectedProxies[group.name] = group.proxies.first;
        }
      }

      // Only after the group table is complete: the engine is told about every
      // group exactly once, and a group added by the fallback above is part of
      // that answer.
      await _syncSelectionsToRustWhenReady();
    } catch (e) {
      debugPrint('Failed to load proxies: $e');
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Load persisted selections from SharedPreferences
  Future<void> _loadPersistedSelections() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Load selected group
      final savedGroup = prefs.getString('selected_proxy_group');
      if (savedGroup != null &&
          _config!.proxyGroups.any((g) => g.name == savedGroup)) {
        _selectedGroupName = savedGroup;
      }

      // Load selected proxies for each group
      for (final group in _config!.proxyGroups) {
        final savedProxy = prefs.getString('selected_proxy_${group.name}');
        if (savedProxy != null && group.proxies.contains(savedProxy)) {
          _selectedProxies[group.name] = savedProxy;
        }
      }
    } catch (e) {
      debugPrint('Failed to load persisted selections: $e');
    }
  }

  /// Apply the current selections to the engine, and remember that they still
  /// need applying when it cannot take them yet.
  Future<void> _syncSelectionsToRustWhenReady() async {
    _attachEngineReadyListener();
    await _applySelectionsToRust();
  }

  /// Re-assert the selections whenever the engine reports itself ready.
  ///
  /// Not gated on a pending flag: the engine is (re)created when the VPN
  /// service starts, and a fresh instance sits on each group's default member
  /// — the first node of the list — until it is told otherwise. That is
  /// exactly the "I picked Singapore and got a Hong Kong IP" report.
  void _attachEngineReadyListener() {
    if (_engineReadyListenerAttached) return;
    _engineReadyListenerAttached = true;
    NativeCoreService.instance.addListener(() {
      if (!NativeCoreService.instance.isReady) return;
      // A pending flag here means the engine has not confirmed the selections
      // yet; re-asserting them is what clears it, so log the reason and the
      // outcome stay connected.
      if (_rustSyncPending) {
        debugPrint('Re-asserting selections the engine has not confirmed');
      }
      unawaited(_applySelectionsToRust());
    });
  }

  /// Apply all current selections to Rust backend
  Future<void> _applySelectionsToRust() async {
    if (!NativeCoreService.instance.isReady) {
      debugPrint('Skipping Rust selection sync: RustLib not initialized');
      _rustSyncPending = _selectedProxies.isNotEmpty;
      return;
    }

    var allApplied = true;
    for (final entry in _selectedProxies.entries) {
      final group = entry.key;
      final wanted = entry.value;
      try {
        final applied = await rust_api.selectProxyInGroup(
          groupName: group,
          proxyName: wanted,
        );
        if (!applied) {
          allApplied = false;
          debugPrint('Engine refused selection $group -> $wanted');
          continue;
        }

        // 接受调用与真的解析到这个节点是两件事，只有后者决定出口 IP。
        // 不读回就永远不知道选择有没有落地：引擎会安静地留在本组默认值
        // （成员列表的第一个），而用户只能从出口 IP 上发现。
        final effective = await rust_api.getSelectedProxyInGroup(
          groupName: group,
        );
        if (effective != null && effective != wanted) {
          allApplied = false;
          debugPrint(
            'Selection mismatch for $group: asked "$wanted", engine reports "$effective"',
          );
        } else {
          debugPrint('Applied selection: $group -> $wanted');
        }
      } catch (e) {
        allApplied = false;
        debugPrint('Failed to apply selection $group -> $wanted: $e');
      }
    }
    _rustSyncPending = !allApplied;
  }

  /// Sync selections to Rust backend (call this after service starts)
  Future<void> syncSelectionsToRust() async {
    await _syncSelectionsToRustWhenReady();
  }

  /// Save selections to SharedPreferences
  Future<void> _saveSelections() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // Save selected group
      if (_selectedGroupName != null) {
        await prefs.setString('selected_proxy_group', _selectedGroupName!);
      }

      // Save selected proxies for each group
      for (final entry in _selectedProxies.entries) {
        await prefs.setString('selected_proxy_${entry.key}', entry.value);
      }
    } catch (e) {
      debugPrint('Failed to save selections: $e');
    }
  }

  /// Load config from raw YAML content
  void loadFromYaml(String yamlContent) {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _config = ConfigConverter.parseClashConfig(yamlContent);

      // Select first group by default
      if (_config!.proxyGroups.isNotEmpty && _selectedGroupName == null) {
        _selectedGroupName = _config!.proxyGroups.first.name;
      }

      // Initialize selected proxies
      for (final group in _config!.proxyGroups) {
        if (!_selectedProxies.containsKey(group.name) &&
            group.proxies.isNotEmpty) {
          _selectedProxies[group.name] = group.proxies.first;
        }
      }

      unawaited(_syncSelectionsToRustWhenReady());
    } catch (e) {
      debugPrint('Failed to parse config: $e');
      _error = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Select a proxy group to display
  void selectGroup(String groupName) {
    _selectedGroupName = groupName;
    _saveSelections();
    notifyListeners();
  }

  /// Select a proxy within a group
  Future<void> selectProxyInGroup(String groupName, String proxyName) async {
    _selectedProxies[groupName] = proxyName;
    _saveSelections();
    notifyListeners();

    // Call Rust API to change proxy selection (only if RustLib is initialized)
    if (!NativeCoreService.instance.isReady) {
      debugPrint('Skipping Rust API call: RustLib not initialized');

      _rustSyncPending = true;
      _attachEngineReadyListener();
      return;
    }

    // Retry logic to ensure selection is applied
    int retryCount = 0;
    const maxRetries = 3;
    bool success = false;

    while (retryCount < maxRetries && !success) {
      try {
        final result = await rust_api.selectProxyInGroup(
          groupName: groupName,
          proxyName: proxyName,
        );
        if (result) {
          // 接受调用与真的解析到这个节点是两件事：只有后者决定出口 IP。
          // 名字在引擎成员表里对不上时，调用会返回成功而引擎仍留在默认节点，
          // 用户只会从出口 IP 上发现——所以必须读回。
          final effective = await rust_api.getSelectedProxyInGroup(
            groupName: groupName,
          );
          if (effective != null && effective != proxyName) {
            debugPrint(
              'Selection mismatch for $groupName: asked "$proxyName", engine reports "$effective" (attempt ${retryCount + 1}/$maxRetries)',
            );
            retryCount++;
            if (retryCount < maxRetries) {
              await Future.delayed(const Duration(milliseconds: 200));
            }
            continue;
          }
          debugPrint('Proxy selection updated: $groupName -> $proxyName');
          success = true;
          _rustSyncPending = false;
          // Notify listeners that proxy selection changed - trigger IP refresh
          proxySelectionChangedController.add(proxyName);
        } else {
          debugPrint(
            'Proxy selection returned false, retrying... (${retryCount + 1}/$maxRetries)',
          );
          retryCount++;
          if (retryCount < maxRetries) {
            await Future.delayed(const Duration(milliseconds: 200));
          }
        }
      } catch (e) {
        debugPrint(
          'Failed to update proxy selection in Rust (attempt ${retryCount + 1}): $e',
        );
        retryCount++;
        if (retryCount < maxRetries) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }
    }

    if (!success) {
      debugPrint(
        'WARNING: Failed to apply proxy selection after $maxRetries attempts',
      );
    }
  }

  /// Get the selected proxy for a group
  String? getSelectedProxyForGroup(String groupName) {
    return _selectedProxies[groupName];
  }

  /// Get latency for a proxy
  LatencyResult? getLatency(String proxyName) {
    return _latencyResults[proxyName];
  }

  /// Test latency for all proxies in the current group (concurrent)
  Future<void> testAllLatencies() async {
    if (_isTesting || selectedGroup == null) return;

    _isTesting = true;
    notifyListeners();

    try {
      final group = selectedGroup!;
      final items = getProxiesForGroup(group);

      // Collect all test futures
      final List<Future<void>> testFutures = [];

      for (final item in items) {
        ParsedProxy? proxy;
        String proxyName;

        if (item is ParsedProxy) {
          proxy = item;
          proxyName = item.name;
        } else if (item is String && item != 'DIRECT' && item != 'REJECT') {
          proxyName = item;
          // Try to find the proxy
          proxy = _config?.proxies.where((p) => p.name == item).firstOrNull;
        } else {
          continue;
        }

        if (proxy?.server != null) {
          // Add concurrent test task
          testFutures.add(_testLatencyAndUpdate(proxyName, proxy!));
        }
      }

      // Run all tests concurrently
      await Future.wait(testFutures);
    } finally {
      _isTesting = false;
      notifyListeners();
    }
  }

  /// Internal method to test latency and update result
  Future<void> _testLatencyAndUpdate(
    String proxyName,
    ParsedProxy proxy,
  ) async {
    final result = await _testLatency(proxyName, proxy);
    _latencyResults[proxyName] = result;
    notifyListeners();
  }

  /// Test latency for a single proxy
  Future<void> testLatency(String proxyName) async {
    final proxy = _config?.proxies
        .where((p) => p.name == proxyName)
        .firstOrNull;
    if (proxy?.server == null) return;

    final result = await _testLatency(proxyName, proxy!);
    _latencyResults[proxyName] = result;
    notifyListeners();
  }

  Future<LatencyResult> _testLatency(
    String proxyName,
    ParsedProxy proxy,
  ) async {
    // Check if RustLib is initialized
    if (!NativeCoreService.instance.isReady) {
      return LatencyResult(
        proxyName: proxyName,
        isSuccess: false,
        error: 'Rust library not initialized',
      );
    }

    try {
      final server = proxy.server;
      if (server == null) {
        return LatencyResult(
          proxyName: proxyName,
          isSuccess: false,
          error: 'No server address',
        );
      }

      String host = server;
      int resolvedPort = proxy.port ?? 0;

      // Handle server:port format
      if (server.contains(':')) {
        final parts = server.split(':');
        host = parts[0];
        if (parts.length > 1 && resolvedPort == 0) {
          resolvedPort = int.tryParse(parts[1]) ?? 0;
        }
      }

      if (resolvedPort == 0) {
        resolvedPort = 443; // Default for most proxy protocols
      }

      final proxyType = proxy.type.toLowerCase();

      if (proxyType == 'ss' || proxyType == 'shadowsocks') {
        final password = proxy.options['password'] as String? ?? '';
        final cipher =
            (proxy.options['cipher'] as String?) ??
            (proxy.options['method'] as String?) ??
            'aes-256-gcm';

        if (password.isEmpty) {
          return LatencyResult(
            proxyName: proxyName,
            isSuccess: false,
            error: 'Missing password',
          );
        }

        try {
          final result = await rust_api.testShadowsocksLatency(
            server: host,
            port: resolvedPort,
            password: password,
            cipher: cipher,
            timeoutMs: 5000,
          );

          return LatencyResult(
            proxyName: proxyName,
            latencyMs: result.latencyMs,
            isSuccess: result.success,
            error: result.error,
          );
        } catch (e) {
          final result = await rust_api.testTcpConnectivity(
            server: host,
            port: resolvedPort,
            timeoutMs: 5000,
          );

          return LatencyResult(
            proxyName: proxyName,
            latencyMs: result.latencyMs,
            isSuccess: result.success,
            error: result.success ? null : e.toString(),
          );
        }
      }

      final result = await rust_api.testTcpConnectivity(
        server: host,
        port: resolvedPort,
        timeoutMs: 5000,
      );

      return LatencyResult(
        proxyName: proxyName,
        latencyMs: result.latencyMs,
        isSuccess: result.success,
        error: result.error,
      );
    } catch (e) {
      return LatencyResult(
        proxyName: proxyName,
        isSuccess: false,
        error: e.toString(),
      );
    }
  }

  /// Clear latency results
  void clearLatencies() {
    _latencyResults.clear();
    notifyListeners();
  }

  /// Clear all data
  void clear() {
    _config = null;
    _selectedGroupName = null;
    _selectedProxies.clear();
    _latencyResults.clear();
    _error = null;
    notifyListeners();
  }
}
