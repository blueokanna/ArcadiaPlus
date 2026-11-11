import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals, compute;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:arcadiaplus/src/rust/api.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:arcadiaplus/src/services/config_converter.dart';
import 'package:arcadiaplus/src/services/platform_proxy_service.dart';
import 'package:arcadiaplus/src/services/native_core_service.dart';
import 'package:arcadiaplus/src/services/rule_provider_service.dart';
import 'package:arcadiaplus/src/services/system_dns_service.dart';
import 'package:arcadiaplus/src/services/profile_selections.dart';
import 'package:arcadiaplus/src/services/service_diagnostics.dart';
import 'package:arcadiaplus/src/services/proxy_engine_service.dart';
import 'package:arcadiaplus/src/utils/app_lifecycle.dart';
import 'package:arcadiaplus/src/utils/platform_utils.dart';
import 'package:arcadiaplus/src/utils/serial_task_queue.dart';

class AppStateProvider extends ChangeNotifier {
  final _operations = SerialTaskQueue();
  late final Future<void> _initialization;
  bool _disposed = false;
  // App state
  ThemeMode _themeMode = ThemeMode.system;
  bool _isServiceRunning = false;
  bool _isInitialized = false;
  ProxyStatus? _proxyStatus;
  TrafficStats? _trafficStats;
  List<ActiveConnection> _activeConnections = [];
  SystemInfo? _systemInfo;
  bool _isLoading = false;
  String? _serviceError;
  String? _initializationError;
  String _version = '';
  String _buildInfo = '';
  ProxyMode _proxyMode = ProxyMode.rule;

  // Auto proxy settings
  bool _autoSystemProxy = true;
  bool _autoVpnClose = true;
  bool _systemProxyEnabledByUs = false;

  // Connection stats from tracker
  BigInt _totalConnections = BigInt.zero;
  BigInt _activeConnectionCount = BigInt.zero;
  BigInt _totalUploadBytes = BigInt.zero;
  BigInt _totalDownloadBytes = BigInt.zero;

  // Timer for system info refresh
  Timer? _systemInfoTimer;
  // Timer for periodic status/traffic/connection refresh
  Timer? _statusTimer;
  // Timer that refreshes rule sets once their interval elapses
  Timer? _ruleSetTimer;

  // Address of the running RecurseX recursive resolver, when enabled
  String? _recursiveDnsAddress;
  String? _recursiveDnsWarning;

  // Current speed values (from Rust tracker)
  BigInt _currentUploadSpeed = BigInt.zero;
  BigInt _currentDownloadSpeed = BigInt.zero;

  // Rule set state, kept so the UI can show freshness and warnings
  RuleProviderReport _ruleSetReport = const RuleProviderReport.empty();
  List<String> _configWarnings = const [];
  bool _isRefreshingRuleSets = false;

  // Profile and config that are currently loaded into the engine, kept for
  // rule set refreshes and for detecting whether a reload is needed.
  String? _activeProfileId;
  String? _appliedConfigJson;
  DnsSettings? _appliedDnsSettings;
  bool _isInitializingProfile = false;

  // Tick counter that paces the slower per-second polls
  int _statusTicks = 0;

  // Getters
  ThemeMode get themeMode => _themeMode;
  bool get isServiceRunning => _isServiceRunning;
  bool get isInitialized => _isInitialized;
  ProxyStatus? get proxyStatus => _proxyStatus;
  TrafficStats? get trafficStats => _trafficStats;
  BigInt get currentUploadSpeed => _currentUploadSpeed;
  BigInt get currentDownloadSpeed => _currentDownloadSpeed;
  List<ActiveConnection> get activeConnections => _activeConnections;
  BigInt get totalConnections => _totalConnections;
  BigInt get activeConnectionCount => _activeConnectionCount;
  BigInt get totalUploadBytes => _totalUploadBytes;
  BigInt get totalDownloadBytes => _totalDownloadBytes;
  SystemInfo? get systemInfo => _systemInfo;
  bool get isLoading => _isLoading;
  String? get serviceError => _serviceError;
  String? get recursiveDnsWarning => _recursiveDnsWarning;
  bool get autoSystemProxy => _autoSystemProxy;
  bool get autoVpnClose => _autoVpnClose;
  ProxyMode get proxyMode => _proxyMode;

  // Version info
  String get version => _version;
  String get buildInfo => _buildInfo;

  /// Rule set snapshot of the loaded profile (freshness, entry counts, errors).
  RuleProviderReport get ruleSetReport => _ruleSetReport;

  /// Conversion warnings of the last generated config (dropped nodes, missing
  /// rule sets, unavailable outbound targets, …).
  List<String> get configWarnings => _configWarnings;

  bool get isRefreshingRuleSets => _isRefreshingRuleSets;

  AppStateProvider() {
    RuleProviderService.instance.addListener(_onRuleProviderRefresh);
    AppLifecycle.instance.active.addListener(_onLifecycleChanged);
    _initialization = _loadSettings().then(
      (_) => _initializeFromActiveProfile(),
    );
    _loadSystemInfo();
    _loadVersionInfo();
    _syncTimers();
    _initializePlatformProxyService();
    PlatformProxyService.instance.onQuickConnectRequested =
        _consumeQuickConnect;
    PlatformProxyService.instance.onVpnStatusChanged = _onVpnStatusChanged;
    unawaited(_initialization.then((_) => _consumeQuickConnect()));
  }

  /// A rule set refresh outside this provider (profile update, manual action)
  /// may have changed the files the engine is reading.
  void _onRuleProviderRefresh() {
    if (_isInitializingProfile || _isRefreshingRuleSets || _disposed) return;
    final profileId = RuleProviderService.instance.lastProfileId;
    if (profileId == null || profileId != _activeProfileId) return;
    refreshRuleSets();
  }

  void _initializePlatformProxyService() {
    debugPrint('=== AppStateProvider: Initializing PlatformProxyService ===');
    final service = PlatformProxyService.instance;
    debugPrint(
      'AppStateProvider: PlatformProxyService initialized, vpnFd=${service.vpnFd}',
    );
  }

  @override
  void dispose() {
    _disposed = true;
    PlatformProxyService.instance.onQuickConnectRequested = null;
    PlatformProxyService.instance.onVpnStatusChanged = null;
    RuleProviderService.instance.removeListener(_onRuleProviderRefresh);
    AppLifecycle.instance.active.removeListener(_onLifecycleChanged);
    _systemInfoTimer?.cancel();
    _statusTimer?.cancel();
    _ruleSetTimer?.cancel();
    super.dispose();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Refresh scheduling
  // ---------------------------------------------------------------------------

  /// How often the live traffic sample is taken. Only runs while a screen is
  /// actually showing it — see [retainLiveStats].
  static const Duration _liveStatsInterval = Duration(seconds: 1);

  /// How often the status and lifetime counters are re-read. They feed a
  /// summary, not a gauge, and each read is a hop across the FFI boundary, so
  /// they are sampled on a slower beat than the traffic figure.
  static const int _slowPollEveryTicks = 5;

  /// How often the system information card is refreshed. The values behind it
  /// move over minutes, and re-reading them is not free on Android; polling
  /// this every five seconds bought nothing but heat.
  static const Duration _systemInfoInterval = Duration(seconds: 30);

  /// How often rule sets are re-checked. Only the providers whose declared
  /// interval has elapsed actually hit the network.
  static const Duration _ruleSetInterval = Duration(minutes: 15);

  /// Screens that display live traffic hold a claim; the fast refresh runs
  /// only while at least one is held. Without this the app would poll at 1 Hz
  /// on the settings screen, where nothing on screen depends on the answer.
  int _liveStatsClaims = 0;

  /// Called from a screen's `initState`; pair with [releaseLiveStats] in
  /// `dispose`.
  void retainLiveStats() {
    _liveStatsClaims++;
    _syncTimers();
  }

  void releaseLiveStats() {
    if (_liveStatsClaims == 0) return;
    _liveStatsClaims--;
    _syncTimers();
  }

  void _onLifecycleChanged() {
    _syncTimers(refreshOnReturn: true);
    if (AppLifecycle.instance.isActive) unawaited(_consumeQuickConnect());
  }

  bool _consumingQuickConnect = false;
  Future<void> _consumeQuickConnect() async {
    if (_disposed || _consumingQuickConnect) return;
    _consumingQuickConnect = true;
    try {
      await _initialization;
      if (await PlatformProxyService.instance.consumeQuickConnect()) {
        await startService();
      }
    } catch (error) {
      debugPrint('Quick connect failed: $error');
    } finally {
      _consumingQuickConnect = false;
    }
  }

  void _onVpnStatusChanged(bool running) {
    if (!running &&
        _isServiceRunning &&
        !_isLoading &&
        !_isRefreshingRuleSets &&
        !_disposed) {
      unawaited(stopService());
    }
  }

  /// Bring the set of running timers in line with what is actually being watched
  void _syncTimers({bool refreshOnReturn = false}) {
    final isActive = AppLifecycle.instance.isActive;
    if (_disposed) return;

    final wantsStatus = isActive && _isServiceRunning && _liveStatsClaims > 0;
    if (wantsStatus) {
      _statusTimer ??= Timer.periodic(
        _liveStatsInterval,
        (_) => _refreshStatus(),
      );
    } else {
      _statusTimer?.cancel();
      _statusTimer = null;
    }

    if (isActive) {
      _systemInfoTimer ??= Timer.periodic(
        _systemInfoInterval,
        (_) => _loadSystemInfo(),
      );
      _ruleSetTimer ??= Timer.periodic(
        _ruleSetInterval,
        (_) => refreshRuleSets(),
      );
    } else {
      _systemInfoTimer?.cancel();
      _systemInfoTimer = null;
      _ruleSetTimer?.cancel();
      _ruleSetTimer = null;
    }

    if (refreshOnReturn && isActive) {
      // Whatever is on screen is stale by however long the app was away.
      if (_isServiceRunning) unawaited(_refreshStatus());
      unawaited(_loadSystemInfo());
      unawaited(refreshRuleSets());
    }
  }

  /// Build the engine from the active profile.
  ///
  /// [startResolver] decides whether the local recursive resolver is brought
  /// up as part of this: it is only needed when the engine is about to run, so
  /// the startup path leaves it alone.
  Future<void> _initializeFromActiveProfile({
    bool startResolver = false,
  }) async {
    _initializationError = null;
    if (!NativeCoreService.instance.isReady) {
      debugPrint('Cannot initialize from profile: RustLib not initialized');
      _isInitialized = false;
      return;
    }

    try {
      _isInitializingProfile = true;
      _configWarnings = const [];
      final activeProfileId = await StorageService.instance
          .getActiveProfileId();
      if (activeProfileId == null) {
        debugPrint('No active profile found');
        _isInitialized = false;
        return;
      }

      final configContent = await StorageService.instance.getProfileConfig(
        activeProfileId,
      );
      if (configContent == null) {
        debugPrint('Active profile config not found');
        _isInitialized = false;
        return;
      }

      final generalSettings = await StorageService.instance
          .getGeneralSettings();
      final dnsSettings = await StorageService.instance.getDnsSettings();

      if (startResolver && !PlatformUtils.isOHOS) {
        await _ensureRecursiveDns(dnsSettings);
      }

      final (jsonConfig, report) = await _generateConfig(
        activeProfileId,
        configContent,
        generalSettings,
        dnsSettings: dnsSettings,
      );

      debugPrint('Calling initializeCorduit...');
      await ConfiguredProxyEngine.instance.configure(activeProfileId, (
        engine,
      ) async {
        await initializeCorduit(configJson: jsonConfig);
        await ProfileSelections.restore(activeProfileId, jsonConfig, engine);
      });
      _activeProfileId = activeProfileId;
      _appliedConfigJson = jsonConfig;
      _appliedDnsSettings = dnsSettings;
      _ruleSetReport = report;
      _isInitialized = true;
      _syncTimers();
      debugPrint(
        'ArcadiaPlus initialized from active profile: $activeProfileId',
      );
      notifyListeners();
    } catch (e, stackTrace) {
      _initializationError = e.toString();
      debugPrint('Failed to initialize from active profile: $e');
      _configWarnings = List.unmodifiable([..._configWarnings, e.toString()]);
      debugPrint('Stack trace: $stackTrace');
      _isInitialized = false;
    } finally {
      _isInitializingProfile = false;
    }
  }

  /// Materialises the profile's rule sets and converts the profile into the
  /// engine's JSON document, collecting every conversion warning.
  Future<(String, RuleProviderReport)> _generateConfig(
    String profileId,
    String configContent,
    GeneralSettings generalSettings, {
    bool forceRuleSets = false,
    DnsSettings? dnsSettings,
  }) async {
    final warnings = <String>[?_recursiveDnsWarning];
    if (PlatformUtils.isMobile && generalSettings.mode == 'direct') {
      generalSettings = generalSettings.copyWith(mode: 'rule');
    }
    dnsSettings ??= await StorageService.instance.getDnsSettings();
    final systemDnsServers =
        generalSettings.appendSystemDns && !dnsSettings.requireEncryptedDns
        ? await SystemDnsService.instance.read()
        : const <String>[];
    final report = await RuleProviderService.instance.prepare(
      profileId,
      configContent,
      force: forceRuleSets,
      onWarning: warnings.add,
    );
    final converted = await compute(_convertProfile, (
      configContent,
      generalSettings,
      dnsSettings,
      _recursiveDnsAddress,
      systemDnsServers,
      report.paths,
    ));
    final jsonConfig = converted.$1;
    warnings.addAll(converted.$2);
    for (final state in report.states) {
      if (state.error != null) {
        debugPrint('Rule provider ${state.name}: ${state.error}');
      }
    }
    _configWarnings = List.unmodifiable(warnings);
    return (jsonConfig, report);
  }

  /// Re-checks every rule set against its declared interval and, when the
  /// resulting config differs from the one the engine holds, reloads it.
  ///
  /// Called by the scheduler and by the UI's "update rule sets" action.
  Future<bool> refreshRuleSets({bool force = false}) =>
      _operations.run(() => _refreshRuleSets(force: force));

  Future<bool> _refreshRuleSets({bool force = false}) async {
    await _initialization;
    if (_isRefreshingRuleSets) return false;

    final profileId =
        _activeProfileId ?? await StorageService.instance.getActiveProfileId();
    if (profileId == null) return false;

    _isRefreshingRuleSets = true;
    notifyListeners();
    try {
      final configContent = await StorageService.instance.getProfileConfig(
        profileId,
      );
      if (configContent == null) return false;

      final generalSettings = await StorageService.instance
          .getGeneralSettings();
      final (jsonConfig, report) = await _generateConfig(
        profileId,
        configContent,
        generalSettings,
        forceRuleSets: force,
        // A rule refresh must not apply DNS preferences promised for next start.
        dnsSettings: _isServiceRunning ? _appliedDnsSettings : null,
      );
      _ruleSetReport = report;

      if (_isServiceRunning && jsonConfig != _appliedConfigJson) {
        await _applyReload(jsonConfig);
      }
      return true;
    } catch (e) {
      debugPrint('Failed to refresh rule sets: $e');
      return false;
    } finally {
      _isRefreshingRuleSets = false;
      notifyListeners();
    }
  }

  /// Bring the RecurseX front-end up when the DNS settings ask for local
  /// recursion, and remember the bound address so the next config
  /// conversion can point corduit at it.
  Future<void> _applyReload(String config) async {
    if (!PlatformUtils.isOHOS) {
      await ConfiguredProxyEngine.instance.configure(_activeProfileId, (
        engine,
      ) async {
        await reloadCorduit(configJson: config);
        if (_activeProfileId != null) {
          await ProfileSelections.restore(_activeProfileId!, config, engine);
        }
      });
      _appliedConfigJson = config;
      return;
    }
    final platform = PlatformProxyService.instance;
    final previous = _appliedConfigJson;
    if (!await platform.disableTunMode()) {
      throw StateError('Cannot stop VPN for reload');
    }
    try {
      _appliedConfigJson = config;
      await _prepareOhosEngine();
      if (!await platform.enableTunMode(mode: _proxyMode)) {
        throw StateError('Extension rejected updated configuration');
      }
    } catch (_) {
      _appliedConfigJson = previous;
      await _prepareOhosEngine();
      _isServiceRunning = await platform.enableTunMode(mode: _proxyMode);
      rethrow;
    }
  }

  Future<void> _ensureRecursiveDns(DnsSettings dnsSettings) async {
    _recursiveDnsWarning = null;
    try {
      if (!dnsSettings.useRecursiveResolver ||
          dnsSettings.requireEncryptedDns) {
        await _stopRecursiveDns();
        return;
      }

      final support = await getApplicationSupportDirectory();
      final cachePath =
          '${support.path}${Platform.pathSeparator}recursion-cache.rxc';
      _recursiveDnsAddress = await startRecursiveDns(
        listen: '127.0.0.1:0',
        cachePath: cachePath,
      );
      debugPrint(
        'RecurseX recursive resolver listening on $_recursiveDnsAddress',
      );
    } catch (e) {
      _recursiveDnsAddress = null;
      _recursiveDnsWarning =
          'Local recursive DNS is unavailable; configured upstreams remain active: $e';
      ServiceDiagnostics.warning(_recursiveDnsWarning!);
      debugPrint(_recursiveDnsWarning);
    }
  }

  Future<void> _stopRecursiveDns() async {
    _recursiveDnsWarning = null;
    try {
      await stopRecursiveDns();
    } catch (e) {
      debugPrint('Failed to stop the recursive resolver: $e');
    } finally {
      _recursiveDnsAddress = null;
    }
  }

  /// Set initialized state (called from ProfilesProvider when profile is selected)
  void setInitialized(bool value) {
    _isInitialized = value;
    notifyListeners();
  }

  // Load version information
  Future<void> _loadVersionInfo() async {
    if (!NativeCoreService.instance.isReady) {
      debugPrint('Skipping version info load: RustLib not initialized');
      return;
    }
    try {
      _version = await getVersion();
      _buildInfo = await getBuildInfo();
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load version info: $e');
    }
  }

  // Load settings from SharedPreferences
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final generalSettings = await StorageService.instance.getGeneralSettings();
    final themeModeString = prefs.getString('themeMode') ?? 'system';
    _themeMode = ThemeMode.values.firstWhere(
      (mode) => mode.name == themeModeString,
      orElse: () => ThemeMode.system,
    );
    _autoSystemProxy = prefs.getBool('autoSystemProxy') ?? true;
    _autoVpnClose = prefs.getBool('autoVpnClose') ?? true;
    _proxyMode = ProxyMode.values.firstWhere(
      (mode) => mode.name == generalSettings.mode,
      orElse: () => ProxyMode.rule,
    );
    final restoredMode = RoutingModes.restore(_proxyMode);
    if (restoredMode != _proxyMode) {
      _proxyMode = restoredMode;
      await StorageService.instance.saveGeneralSettings(
        generalSettings.copyWith(mode: restoredMode.name),
      );
    }
    if (NativeCoreService.instance.isReady) {
      await PlatformProxyService.instance.configureProxyMode(_proxyMode);
    }
    notifyListeners();
  }

  // Save settings to SharedPreferences
  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('themeMode', _themeMode.name);
    await prefs.setBool('autoSystemProxy', _autoSystemProxy);
    await prefs.setBool('autoVpnClose', _autoVpnClose);
  }

  // Auto proxy settings
  Future<void> setAutoSystemProxy(bool value) async {
    _autoSystemProxy = value;
    await _saveSettings();
    notifyListeners();
  }

  Future<void> setAutoVpnClose(bool value) async {
    _autoVpnClose = value;
    await _saveSettings();
    notifyListeners();
  }

  Future<bool> setProxyMode(ProxyMode mode) =>
      _operations.run(() => _setProxyMode(mode));

  Future<bool> _setProxyMode(ProxyMode mode) async {
    await _initialization;
    if (!RoutingModes.available().contains(mode)) return false;
    if (_proxyMode == mode) return true;

    final previousMode = _proxyMode;

    try {
      final settings = await StorageService.instance.getGeneralSettings();
      if (NativeCoreService.instance.isReady) {
        final applied = await PlatformProxyService.instance.configureProxyMode(
          mode,
        );
        if (!applied) {
          throw StateError('Native router rejected ${mode.name} mode');
        }
      }
      await StorageService.instance.saveGeneralSettings(
        settings.copyWith(mode: mode.name),
      );
      _proxyMode = mode;
      notifyListeners();
      return true;
    } catch (error) {
      if (NativeCoreService.instance.isReady) {
        await PlatformProxyService.instance.configureProxyMode(previousMode);
      }
      _proxyMode = previousMode;
      notifyListeners();
      debugPrint('Failed to set proxy mode: $error');
      return false;
    }
  }

  // Load system information
  Future<void> _loadSystemInfo() async {
    if (!NativeCoreService.instance.isReady) {
      debugPrint('Skipping system info load: RustLib not initialized');
      return;
    }
    try {
      final info = await getSystemInfo();
      if (info == _systemInfo) return;
      _systemInfo = info;
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load system info: $e');
    }
  }

  // Theme management
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _saveSettings();
    notifyListeners();
  }

  // Service management
  Future<bool> startService() => _operations.run(_startService);

  Future<bool> _startService() async {
    await _initialization;
    if (_isServiceRunning) return true;
    if (!NativeCoreService.instance.isReady) {
      _serviceError =
          NativeCoreService.instance.lastError ?? 'Native core is not ready';
      ServiceDiagnostics.failure(_serviceError!);
      notifyListeners();
      debugPrint('Cannot start service: RustLib not initialized');
      return false;
    }

    _isLoading = true;
    _serviceError = null;
    notifyListeners();

    try {
      debugPrint('Re-initializing ArcadiaPlus...');
      await _initializeFromActiveProfile(startResolver: true);

      if (!_isInitialized) {
        throw StateError(
          _initializationError ?? 'No usable profile is selected',
        );
      }

      debugPrint('Starting ArcadiaPlus proxy...');
      if (PlatformUtils.isOHOS) {
        await _prepareOhosEngine();
        if (!await PlatformProxyService.instance.enableTunMode(
          mode: _proxyMode,
        )) {
          throw StateError('HarmonyOS VPN could not be established');
        }
      } else {
        await startCorduit();
      }
      if (!await PlatformProxyService.instance.configureProxyMode(_proxyMode)) {
        throw StateError('Cannot apply the selected routing mode');
      }

      if (!PlatformUtils.isOHOS) {
        final status = await getCorduitStatus();
        if (!status.running) {
          throw StateError('Proxy engine stopped during startup');
        }
        _proxyStatus = status;
      }

      if (PlatformUtils.isDesktop && _autoSystemProxy) {
        final generalSettings = await StorageService.instance
            .getGeneralSettings();
        final networkSettings = await StorageService.instance
            .getNetworkSettings();
        final port = generalSettings.mixedPort;
        final proxyHost = generalSettings.bindAddress.contains(':')
            ? '::1'
            : '127.0.0.1';
        debugPrint('Auto enabling system proxy on port $port...');
        final success = await PlatformProxyService.instance.enableSystemProxy(
          host: proxyHost,
          httpPort: port,
          bypass: networkSettings.bypassDomains,
        );
        if (success) {
          _systemProxyEnabledByUs = true;
          debugPrint('System proxy enabled automatically');
        } else {
          debugPrint('Failed to enable system proxy automatically');
        }
      }

      if (Platform.isAndroid) {
        if (!await _enableAndroidVpnWithRetry()) {
          throw StateError(
            PlatformProxyService.instance.lastTunError ??
                'Android VPN could not be established',
          );
        }
      }

      _isServiceRunning = true;
      _syncTimers();
      debugPrint('ArcadiaPlus proxy started successfully');
      return true;
    } catch (e, stackTrace) {
      _serviceError = e.toString();
      ServiceDiagnostics.failure(_serviceError!);
      debugPrint('Failed to start service: $e');
      debugPrint('Stack trace: $stackTrace');
      await _stopService();
      _isInitialized = false;
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> stopService() => _operations.run(_stopService);

  Future<void> _stopService() async {
    await _initialization;
    _isLoading = true;
    notifyListeners();

    try {
      debugPrint('Stopping ArcadiaPlus service...');

      _isServiceRunning = false;
      _syncTimers();

      if (Platform.isAndroid ||
          PlatformUtils.isOHOS ||
          PlatformProxyService.instance.tunModeEnabled) {
        if (!await PlatformProxyService.instance.disableTunMode()) {
          throw StateError(
            'Tunnel cleanup failed; keeping the proxy available',
          );
        }
        debugPrint('VPN disabled automatically');

        // Wait for VPN to fully disconnect
        await Future.delayed(const Duration(milliseconds: 500));
      }
      if (PlatformUtils.isDesktop) {
        final generalSettings = await StorageService.instance
            .getGeneralSettings();
        final platformProxy = PlatformProxyService.instance;
        final ours =
            _systemProxyEnabledByUs ||
            await platformProxy.isSystemProxyPointingAt(
              generalSettings.mixedPort,
            );
        if (ours && await platformProxy.checkSystemProxyStatus()) {
          debugPrint('Auto disabling system proxy...');
          await platformProxy.disableSystemProxy();
          _systemProxyEnabledByUs = false;
          debugPrint('System proxy disabled automatically');
        }
      }

      await ConfiguredProxyEngine.instance.stop(stopCorduit);
      await _stopRecursiveDns();
      _isServiceRunning = false;
      _appliedDnsSettings = null;
      _isInitialized = false;
      _proxyStatus = null;
      _trafficStats = null;
      _activeConnections = const [];
      _totalConnections = BigInt.zero;
      _activeConnectionCount = BigInt.zero;
      _totalUploadBytes = BigInt.zero;
      _totalDownloadBytes = BigInt.zero;
      _currentUploadSpeed = BigInt.zero;
      _currentDownloadSpeed = BigInt.zero;
      debugPrint('ArcadiaPlus service stopped');
    } catch (e) {
      debugPrint('Failed to stop service: $e');
      try {
        _isServiceRunning = PlatformUtils.isOHOS
            ? await PlatformProxyService.instance.checkTunModeStatus()
            : (await getCorduitStatus()).running;
      } catch (_) {
        _isServiceRunning = PlatformProxyService.instance.tunModeEnabled;
      }
      _syncTimers();
      _isInitialized = false;
      _currentUploadSpeed = BigInt.zero;
      _currentDownloadSpeed = BigInt.zero;
      _activeConnections = const [];
      _totalConnections = BigInt.zero;
      _activeConnectionCount = BigInt.zero;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> restartService() => _operations.run(() async {
    await _stopService();
    await _startService();
  });

  /// Materialise what the HarmonyOS extension process needs to run the engine.
  ///
  /// The extension shares the app's sandbox but not this process's memory:
  /// the generated config and the unpacked GeoIP database reach it as files
  /// and paths, carried in the tunnel-start request. The engine log lands
  /// beside them, which is also where the settings screen looks when a start
  /// fails.
  Future<void> _prepareOhosEngine() async {
    final config = _appliedConfigJson;
    if (config == null) {
      throw StateError('No configuration for the VPN extension');
    }
    try {
      final support = await getApplicationSupportDirectory();
      final directory = Directory(
        '${support.path}${Platform.pathSeparator}engine',
      );
      await directory.create(recursive: true);
      final file = File(
        '${directory.path}${Platform.pathSeparator}config.json',
      );
      await file.writeAsString(config, flush: true);
      PlatformProxyService.instance.prepareOhosEngine(
        configPath: file.path,
        geoipPath: NativeCoreService.instance.geoIpDatabasePath,
        logPath: '${directory.path}${Platform.pathSeparator}engine.log',
      );
    } catch (e) {
      debugPrint('Failed to prepare the HarmonyOS engine files: $e');
      rethrow;
    }
  }

  /// Brings the Android VPN up, retrying briefly: the platform needs a moment
  /// to release the VPN slot after a competing tunnel is torn down.
  Future<bool> _enableAndroidVpnWithRetry({int attempts = 3}) async {
    // Read once per start: the route set is fixed when the tunnel is
    // established, so a value that changed mid-retry could not apply anyway.
    final allowLan =
        (await StorageService.instance.getGeneralSettings()).allowLan;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (await PlatformProxyService.instance.enableTunMode(
        mode: _proxyMode,
        allowLan: allowLan,
      )) {
        return true;
      }
      if (attempt < attempts) {
        await Future.delayed(const Duration(milliseconds: 800));
      }
    }
    return false;
  }

  // Status refresh
  // Flag to prevent concurrent refresh calls
  bool _isRefreshing = false;

  /// Sample the engine's live figures.
  ///
  /// Two rules keep this affordable:
  ///
  /// * **Sample as little as the screen needs.** The traffic figure feeds a
  ///   live chart, so it is read on every tick. The status and the lifetime
  ///   counters feed a summary card, so they ride a slower beat — they used to
  ///   be read every second, which meant four FFI hops per second, forever, to
  ///   discover that nothing had changed. The connection list is not read here
  ///   at all: its screen asks for it through [refreshConnections].
  /// * **Only speak up when something changed.** An idle proxy produces the
  ///   same zero speeds every tick; notifying on those rebuilds the home
  ///   screen once a second for no visible difference.
  Future<void> _refreshStatus() async {
    // A listener being up does not mean the VPN startup transaction committed.
    if (_isLoading || _disposed) return;
    if (PlatformUtils.isOHOS) {
      if (_isLoading || _isRefreshingRuleSets) return;
      final running = await PlatformProxyService.instance.checkTunModeStatus();
      if (!_isLoading && running != _isServiceRunning) {
        _isServiceRunning = running;
        _syncTimers();
        notifyListeners();
      }
      return;
    }
    if (!NativeCoreService.instance.isReady) {
      debugPrint('Skipping status refresh: RustLib not initialized');
      return;
    }

    if (_isRefreshing) {
      return;
    }
    _isRefreshing = true;

    try {
      var changed = false;
      _statusTicks++;
      final sampleSlow = _statusTicks % _slowPollEveryTicks == 0;

      if (sampleSlow) {
        final status = await getCorduitStatus();
        if (status != _proxyStatus) {
          _proxyStatus = status;
          changed = true;
        }
        if (_proxyStatus != null) {
          if (_proxyStatus!.running) {
            if (!_isServiceRunning) {
              _isServiceRunning = true;
              changed = true;
              _syncTimers();
            }
          } else if (_isServiceRunning && !_isLoading) {
            debugPrint(
              'WARNING: Proxy reports not running, but _isServiceRunning is true',
            );
            _isServiceRunning = false;
            changed = true;
            _syncTimers();
          }
        }
      }

      final traffic = await getTrafficStats();
      if (traffic != _trafficStats) {
        _trafficStats = traffic;
        changed = true;
      }

      // Use speed values directly from Rust tracker.
      if (_trafficStats != null) {
        final upload = _trafficStats!.uploadSpeed;
        final download = _trafficStats!.downloadSpeed;
        if (upload != _currentUploadSpeed) {
          _currentUploadSpeed = upload;
          changed = true;
        }
        if (download != _currentDownloadSpeed) {
          _currentDownloadSpeed = download;
          changed = true;
        }
      }

      if (!_isServiceRunning &&
          (_currentUploadSpeed != BigInt.zero ||
              _currentDownloadSpeed != BigInt.zero)) {
        _currentUploadSpeed = BigInt.zero;
        _currentDownloadSpeed = BigInt.zero;
        changed = true;
      }

      if (changed) notifyListeners();
    } catch (e) {
      debugPrint('Failed to refresh status: $e');
    } finally {
      _isRefreshing = false;
    }
  }

  /// Manual refresh (pull to refresh, the app-bar button, returning to a
  /// screen). Forces the slower samples as well, so a deliberate refresh
  /// really does refresh everything instead of waiting for the next slow tick.
  Future<void> refreshStatus() async {
    _statusTicks = _slowPollEveryTicks - 1;
    await _refreshStatus();
  }

  // ---- Connection list -------------------------------------------------------

  bool _isRefreshingConnections = false;

  /// Re-read the connection list and the lifetime counters that head it.
  Future<void> refreshConnections() async {
    if (!NativeCoreService.instance.isReady || !_isServiceRunning) return;
    if (_isRefreshingConnections) return;
    _isRefreshingConnections = true;
    try {
      var changed = false;

      final connections = await getActiveConnections();
      if (!listEquals(connections, _activeConnections)) {
        _activeConnections = List.unmodifiable(connections);
        changed = true;
      }

      final stats = await getConnectionStats();
      if (stats.$1 != _totalConnections) {
        _totalConnections = stats.$1;
        changed = true;
      }
      if (stats.$2 != _totalUploadBytes) {
        _totalUploadBytes = stats.$2;
        changed = true;
      }
      if (stats.$3 != _totalDownloadBytes) {
        _totalDownloadBytes = stats.$3;
        changed = true;
      }
      if (stats.$4 != _activeConnectionCount) {
        _activeConnectionCount = stats.$4;
        changed = true;
      }

      if (changed) notifyListeners();
    } catch (e) {
      debugPrint('Failed to refresh connections: $e');
    } finally {
      _isRefreshingConnections = false;
    }
  }

  // Configuration management
  Future<bool> testConfiguration(String configJson) async {
    if (!NativeCoreService.instance.isReady) {
      debugPrint('Cannot test config: RustLib not initialized');
      return false;
    }
    try {
      return await testConfig(configJson: configJson);
    } catch (e) {
      debugPrint('Failed to test configuration: $e');
      return false;
    }
  }

  Future<void> loadConfiguration(String configJson) =>
      _operations.run(() => _updateConfiguration(configJson, reload: false));

  Future<void> reloadConfiguration(String configJson) =>
      _operations.run(() => _updateConfiguration(configJson, reload: true));

  Future<void> _updateConfiguration(
    String configJson, {
    required bool reload,
  }) async {
    await _initialization;
    if (!NativeCoreService.instance.isReady) {
      throw StateError('The native core is not ready');
    }
    _isLoading = true;
    notifyListeners();
    try {
      // Replacing an initialized engine under a live tunnel loses its listeners.
      if (reload || _isServiceRunning) {
        await _applyReload(configJson);
      } else {
        await ConfiguredProxyEngine.instance.configure(_activeProfileId, (
          _,
        ) async {
          await initializeCorduit(configJson: configJson);
        });
        _isInitialized = true;
        _appliedConfigJson = configJson;
      }
      await _refreshStatus();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  // Connection management
  Future<void> closeConnectionById(String connectionId) async {
    if (!NativeCoreService.instance.isReady) return;
    try {
      await closeConnection(connectionId: connectionId);
      await _refreshStatus();
    } catch (e) {
      debugPrint('Failed to close connection: $e');
    }
  }

  /// Close an active connection by ID (using connection tracker)
  Future<bool> closeActiveConnectionById(String connectionId) async {
    if (!NativeCoreService.instance.isReady) return false;
    try {
      final result = await closeActiveConnection(connectionId: connectionId);
      await _refreshStatus();
      return result;
    } catch (e) {
      debugPrint('Failed to close active connection: $e');
      return false;
    }
  }

  Future<void> closeAllActiveConnections() async {
    if (!NativeCoreService.instance.isReady) return;
    try {
      await closeAllConnections();
      await _refreshStatus();
    } catch (e) {
      debugPrint('Failed to close all connections: $e');
      for (final connection in _activeConnections) {
        try {
          await closeActiveConnectionById(connection.id);
        } catch (e) {
          debugPrint('Failed to close connection ${connection.id}: $e');
        }
      }
      await _refreshStatus();
    }
  }

  /// Pushes a level into the subscriber of the already running process.
  ///
  /// The persisted value belongs to `GeneralSettings`; this is only the live
  /// half, so that changing the level takes effect without a restart. When
  /// the bridge is not up yet there is nothing to apply it to — the level
  /// travels through the configuration on the next start — which is not a
  /// failure. `false` means the engine refused it, and the caller has to say so.
  Future<bool> applyLogLevel(String level) async {
    if (!NativeCoreService.instance.isReady) {
      return true;
    }
    try {
      await setLogLevel(level: level);
      return true;
    } catch (e) {
      debugPrint('Failed to apply log level $level: $e');
      return false;
    }
  }

  // Get formatted traffic data
  String getFormattedTraffic(BigInt bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unitIndex = 0;

    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }

    // Always show 2 decimal places for better precision
    return '${value.toStringAsFixed(2)} ${units[unitIndex]}';
  }

  String getFormattedSpeed(BigInt bytesPerSecond) {
    return '${getFormattedTraffic(bytesPerSecond)}/s';
  }

  // Get connection status color
  Color getConnectionStatusColor() {
    if (_isServiceRunning) {
      return const Color(0xFF146C2E); // Success green
    } else {
      return const Color(0xFFBA1A1A); // Error red
    }
  }

  // Get connection status text
  String getConnectionStatusText() {
    if (_isLoading) {
      return 'Connecting...';
    } else if (_isServiceRunning) {
      return 'Connected';
    } else {
      return 'Disconnected';
    }
  }
}

// Parsing large subscriptions must not compete with gestures and frame layout.
(String, List<String>) _convertProfile(
  (
    String,
    GeneralSettings,
    DnsSettings,
    String?,
    List<String>,
    Map<String, String>,
  )
  input,
) {
  final warnings = <String>[];
  final json = ConfigConverter.convertClashYamlToJson(
    input.$1,
    generalSettings: input.$2,
    dnsSettings: input.$3,
    recursiveDnsAddress: input.$4,
    systemDnsServers: input.$5,
    ruleProviderPaths: input.$6,
    requireCompleteRules: true,
    onWarning: warnings.add,
  );
  return (json, warnings);
}
