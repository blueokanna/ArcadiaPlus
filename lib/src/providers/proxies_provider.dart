import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:arcadiaplus/src/services/config_converter.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:arcadiaplus/src/services/proxy_engine_service.dart';
import 'package:arcadiaplus/src/services/proxy_selection_service.dart';
import 'package:arcadiaplus/src/utils/serial_task_queue.dart';
import 'package:arcadiaplus/src/services/proxy_selection_events.dart';
import 'package:arcadiaplus/src/services/profile_selections.dart';

class LatencyResult {
  final String proxyName;
  final int? latencyMs;
  final bool isSuccess;
  final String? error;
  const LatencyResult({
    required this.proxyName,
    this.latencyMs,
    this.isSuccess = false,
    this.error,
  });
}

class ProxiesProvider extends ChangeNotifier {
  ProxiesProvider({
    ProxyEngine? engine,
    Future<SharedPreferences> Function()? preferences,
    this.prepareEngine,
  }) : _engine = engine ?? ConfiguredProxyEngine.instance,
       _preferences = preferences ?? SharedPreferences.getInstance {
    _engine.addListener(_onEngineChanged);
  }

  final ProxyEngine _engine;
  final Future<void> Function()? prepareEngine;
  final Future<SharedPreferences> Function() _preferences;
  late final _selection = ProxySelectionService(_engine);
  final _operations = SerialTaskQueue();
  final _persistence = SerialTaskQueue();
  ParsedClashConfig? _config;
  String? _profileDigest;
  String? _profileId;
  String? _selectedGroupName;
  final Map<String, String> _selectedProxies = {};
  final Map<String, LatencyResult> _latencyResults = {};
  final Map<String, ParsedProxy> _proxiesByName = {};
  final Map<String, ParsedProxyGroup> _groupsByName = {};
  final Map<String, int> _pendingSelections = {};
  final Map<String, Future<void>> _probes = {};
  final Queue<Completer<void>> _probeWaiters = Queue();
  int _activeProbes = 0;
  int _generation = 0;
  int _measurementGeneration = 0;
  bool _disposed = false;
  bool _isLoading = false;
  bool _isTesting = false;
  String? _error;
  String searchQuery = '';

  static const maxConcurrentProbes = 4;
  ParsedClashConfig? get config => _config;
  String? get selectedGroupName => _selectedGroupName;
  Map<String, String> get selectedProxies =>
      UnmodifiableMapView(_selectedProxies);
  Map<String, LatencyResult> get latencyResults =>
      UnmodifiableMapView(_latencyResults);
  bool get isLoading => _isLoading;
  bool get isTesting => _isTesting;
  bool get canTestLatency =>
      _engine.isReady && _engine.supportsProfile(_profileId);
  String? get error => _error;
  List<ParsedProxyGroup> get proxyGroups => _config?.proxyGroups ?? const [];
  List<ParsedProxy> get proxies => _config?.proxies ?? const [];
  ParsedProxyGroup? get selectedGroup => _groupsByName[_selectedGroupName];
  bool isSelecting(String group) => (_pendingSelections[group] ?? 0) > 0;
  bool canSelectGroup(String name) {
    final group = _groupsByName[name];
    return group != null &&
        !const {
          'url-test',
          'fallback',
          'load-balance',
          'relay',
        }.contains(group.type.toLowerCase());
  }

  List<Object> getProxiesForGroup(ParsedProxyGroup group) => [
    for (final name in group.proxies)
      _groupsByName[name] ?? _proxiesByName[name] ?? name,
  ];

  bool _current(int generation) => !_disposed && generation == _generation;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _onEngineChanged() {
    if (_disposed) return;
    _measurementGeneration++;
    _latencyResults.clear();
    if (canTestLatency) unawaited(syncSelectionsToRust());
    _notify();
  }

  Future<void> loadFromActiveProfile() => _operations.run(() async {
    if (_disposed) return;
    final generation = ++_generation;
    _measurementGeneration++;
    _isLoading = true;
    _error = null;
    _notify();
    try {
      await prepareEngine?.call();
      final id = await StorageService.instance.getActiveProfileId();
      final yaml = id == null
          ? null
          : await StorageService.instance.getProfileConfig(id);
      if (!_current(generation)) return;
      if (_profileId != id) {
        _profileId = id;
        _profileDigest = null;
        _replaceConfig(null);
        _selectedProxies.clear();
        _selectedGroupName = null;
      }
      if (yaml == null) {
        _replaceConfig(null);
        _profileDigest = null;
        _error = 'No active profile';
        return;
      }
      final digest = sha256.convert(utf8.encode(yaml)).toString();
      if (_config != null && _profileDigest == '$id:$digest') {
        await _syncSelections(generation);
        return;
      }
      final parsed = await compute(ConfigConverter.parseProxyConfig, yaml);
      if (!_current(generation)) return;
      _replaceConfig(parsed);
      _profileDigest = null;
      final prefs = await _preferences();
      if (!_current(generation)) return;
      final savedGroup = prefs.getString(ProfileSelections.groupKey(id));
      if (_groupsByName.containsKey(savedGroup)) {
        _selectedGroupName = savedGroup;
      }
      for (final group in proxyGroups) {
        if (!canSelectGroup(group.name)) continue;
        final saved = prefs.getString(ProfileSelections.key(id, group.name));
        if (saved != null && group.proxies.contains(saved)) {
          _selectedProxies[group.name] = saved;
        }
      }
      await _syncSelections(generation);
      if (_current(generation)) _profileDigest = '$id:$digest';
    } catch (error) {
      if (_current(generation)) _error = error.toString();
    } finally {
      if (_current(generation)) {
        _isLoading = false;
        _notify();
      }
    }
  });

  void _replaceConfig(ParsedClashConfig? config) {
    _config = config;
    _proxiesByName
      ..clear()
      ..addEntries(proxies.map((p) => MapEntry(p.name, p)));
    _groupsByName
      ..clear()
      ..addEntries(proxyGroups.map((g) => MapEntry(g.name, g)));
    _selectedProxies.removeWhere(
      (group, proxy) =>
          !canSelectGroup(group) ||
          !(_groupsByName[group]?.proxies.contains(proxy) ?? false),
    );
    for (final group in proxyGroups) {
      if (canSelectGroup(group.name) && group.proxies.isNotEmpty) {
        _selectedProxies.putIfAbsent(group.name, () => group.proxies.first);
      }
    }
    if (!_groupsByName.containsKey(_selectedGroupName)) {
      _selectedGroupName = proxyGroups.firstOrNull?.name;
    }
    _latencyResults.clear();
  }

  void loadFromYaml(String yamlContent) {
    if (_disposed) return;
    _generation++;
    _measurementGeneration++;
    _isLoading = false;
    _profileDigest = null;
    try {
      _replaceConfig(ConfigConverter.parseProxyConfig(yamlContent));
      _error = null;
      unawaited(syncSelectionsToRust());
    } catch (error) {
      _error = error.toString();
    }
    _notify();
  }

  void selectGroup(String groupName) {
    if (_disposed ||
        !_groupsByName.containsKey(groupName) ||
        groupName == _selectedGroupName) {
      return;
    }
    _selectedGroupName = groupName;
    unawaited(_saveSelections());
    _notify();
  }

  Future<void> selectProxyInGroup(String groupName, String proxyName) async {
    if (_disposed ||
        !canSelectGroup(groupName) ||
        !(_groupsByName[groupName]?.proxies.contains(proxyName) ?? false)) {
      return;
    }
    final generation = _generation;
    _pendingSelections.update(
      groupName,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
    _notify();
    try {
      await _operations.run(() async {
        if (!_current(generation)) return;
        _error = null;
        if (await _applySelection(groupName, proxyName, generation)) {
          await _saveSelections();
        }
      });
    } finally {
      final count = (_pendingSelections[groupName] ?? 1) - 1;
      if (count <= 0) {
        _pendingSelections.remove(groupName);
      } else {
        _pendingSelections[groupName] = count;
      }
      _notify();
    }
  }

  Future<void> syncSelectionsToRust() {
    final generation = _generation;
    return _operations.run(() => _syncSelections(generation));
  }

  Future<void> _syncSelections(int generation) async {
    if (!_current(generation) || !canTestLatency) return;
    _error = null;
    var applied = false;
    for (final entry in _selectedProxies.entries.toList(growable: false)) {
      if (!_current(generation)) return;
      final updated = await _applySelection(entry.key, entry.value, generation);
      applied = applied || updated;
    }
    if (!_current(generation)) return;
    if (applied) {
      await _saveSelections();
    }
    _notify();
  }

  Future<bool> _applySelection(
    String group,
    String member,
    int generation,
  ) async {
    if (!_current(generation)) return false;
    if (canTestLatency) {
      final result = await _selection.select(
        group,
        member,
        isCurrent: () => _current(generation) && canTestLatency,
      );
      if (result == null || !_current(generation)) return false;
      if (result.changed) ProxySelectionEvents.applied(group);
      final effective = result.member;
      if (effective != null &&
          (_groupsByName[group]?.proxies.contains(effective) ?? false)) {
        _selectedProxies[group] = effective;
      } else {
        // Never retain a checkmark or saved preference for unconfirmed state.
        _selectedProxies.remove(group);
      }
      if (result.error != null) _error = result.error.toString();
    } else {
      _selectedProxies[group] = member;
    }
    return true;
  }

  Future<void> _saveSelections() async {
    final generation = _generation;
    final profileId = _profileId;
    final group = _selectedGroupName;
    final groups = _groupsByName.keys.toList(growable: false);
    final selections = Map<String, String>.of(_selectedProxies);
    try {
      await _persistence.run(() async {
        if (!_current(generation)) return;
        final prefs = await _preferences();
        if (!_current(generation)) return;
        if (group != null &&
            prefs.getString(ProfileSelections.groupKey(profileId)) != group &&
            !await prefs.setString(
              ProfileSelections.groupKey(profileId),
              group,
            )) {
          throw StateError('Could not save proxy group');
        }
        for (final name in groups) {
          if (!_current(generation)) return;
          final key = ProfileSelections.key(profileId, name);
          final member = selections[name];
          if (prefs.getString(key) == member) continue;
          final saved = member == null
              ? await prefs.remove(key)
              : await prefs.setString(key, member);
          if (!saved) throw StateError('Could not save proxy selection');
        }
      });
    } catch (error) {
      if (_current(generation)) {
        _error ??= 'Could not save proxy preferences: $error';
        _notify();
      }
    }
  }

  String? getSelectedProxyForGroup(String groupName) =>
      _selectedProxies[groupName];
  LatencyResult? getLatency(String proxyName) => _latencyResults[proxyName];

  Future<void> testAllLatencies() async {
    if (_disposed || _isTesting || !canTestLatency || selectedGroup == null) {
      return;
    }
    final group = selectedGroup!;
    final names = group.proxies
        .where(_proxiesByName.containsKey)
        .toSet()
        .toList();
    final generation = _generation;
    final measurementGeneration = _measurementGeneration;
    _isTesting = true;
    _notify();
    var next = 0;
    Future<void> worker() async {
      while (_current(generation) &&
          measurementGeneration == _measurementGeneration &&
          next < names.length) {
        final name = names[next++];
        await _measure(name, group.url);
      }
    }

    try {
      await Future.wait(
        List.generate(
          names.length.clamp(0, maxConcurrentProbes),
          (_) => worker(),
        ),
      );
    } finally {
      _isTesting = false;
      _notify();
    }
  }

  Future<void> testLatency(String proxyName) {
    if (_disposed ||
        !canTestLatency ||
        !_proxiesByName.containsKey(proxyName)) {
      return Future.value();
    }
    return _measure(proxyName, selectedGroup?.url);
  }

  Future<void> _measure(String name, String? url) {
    final generation = _generation;
    final measurementGeneration = _measurementGeneration;
    final key = '$generation:$measurementGeneration:$name:${url ?? ''}';
    return _probes.putIfAbsent(key, () {
      final operation = _runProbe(name, url, generation, measurementGeneration);
      return operation.whenComplete(() {
        _probes.remove(key);
      });
    });
  }

  Future<void> _runProbe(
    String name,
    String? url,
    int generation,
    int measurementGeneration,
  ) async {
    if (_activeProbes >= maxConcurrentProbes) {
      final waiter = Completer<void>();
      _probeWaiters.add(waiter);
      await waiter.future;
    } else {
      _activeProbes++;
    }
    try {
      if (!_current(generation) ||
          measurementGeneration != _measurementGeneration) {
        return;
      }
      LatencyResult result;
      try {
        if (!canTestLatency) throw StateError('Proxy core is not ready');
        final ms = await _engine.measure(
          name,
          url?.isNotEmpty == true
              ? url!
              : 'http://www.gstatic.com/generate_204',
        );
        result = LatencyResult(proxyName: name, latencyMs: ms, isSuccess: true);
      } catch (error) {
        result = LatencyResult(proxyName: name, error: error.toString());
      }
      if (_current(generation) &&
          measurementGeneration == _measurementGeneration) {
        _latencyResults[name] = result;
        _notify();
      }
    } finally {
      if (_probeWaiters.isEmpty) {
        _activeProbes--;
      } else {
        _probeWaiters.removeFirst().complete();
      }
    }
  }

  void clearLatencies() {
    _measurementGeneration++;
    _latencyResults.clear();
    _notify();
  }

  void clear() {
    if (_disposed) return;
    _generation++;
    _measurementGeneration++;
    _replaceConfig(null);
    _isLoading = false;
    _error = null;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _engine.removeListener(_onEngineChanged);
    super.dispose();
  }
}
