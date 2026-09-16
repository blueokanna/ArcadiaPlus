import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:veloguard/src/rust/api.dart';
import 'package:veloguard/src/rust/types.dart';
import 'package:veloguard/src/services/storage_service.dart';
import 'package:veloguard/src/services/config_converter.dart';
import 'package:veloguard/src/services/platform_proxy_service.dart';
import 'package:veloguard/src/services/native_core_service.dart';
import 'package:veloguard/src/services/rule_provider_service.dart';
import 'package:veloguard/src/utils/platform_utils.dart';

class AppStateProvider extends ChangeNotifier {
  // App state
  ThemeMode _themeMode = ThemeMode.system;
  bool _isServiceRunning = false;
  bool _isInitialized = false;
  ProxyStatus? _proxyStatus;
  TrafficStats? _trafficStats;
  List<ActiveConnection> _activeConnections = [];
  SystemInfo? _systemInfo;
  bool _isLoading = false;
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
    _loadSettings();
    _loadSystemInfo();
    _loadVersionInfo();
    _initializeFromActiveProfile();
    _startSystemInfoTimer();
    _initializePlatformProxyService();
  }

  /// A rule set refresh outside this provider (profile update, manual action)
  /// may have changed the files the engine is reading.
  void _onRuleProviderRefresh() {
    if (_isInitializingProfile) return;
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
    RuleProviderService.instance.removeListener(_onRuleProviderRefresh);
    _systemInfoTimer?.cancel();
    _statusTimer?.cancel();
    _ruleSetTimer?.cancel();
    super.dispose();
  }

  // Start 5-second timer for system info refresh
  void _startSystemInfoTimer() {
    _systemInfoTimer?.cancel();
    _systemInfoTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _loadSystemInfo();
    });
  }

  // Start 1-second timer for live status/traffic/connection refresh
  void _startStatusTimer() {
    // Cancel any existing timer first to prevent duplicates
    _statusTimer?.cancel();
    _statusTimer = null;

    // Only start timer if service is running
    if (!_isServiceRunning) {
      return;
    }

    _statusTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      // Double-check service is still running before refreshing
      if (_isServiceRunning && !_isLoading) {
        await _refreshStatus();
      }
    });
  }

  void _stopStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  // Initialize VeloGuard from active profile on startup
  Future<void> _initializeFromActiveProfile() async {
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

      // Bring the recursive resolver up before the config is generated so
      // the DNS section can point corduit at it.
      await _ensureRecursiveDns();

      final (jsonConfig, report) = await _generateConfig(
        activeProfileId,
        configContent,
        generalSettings,
      );

      debugPrint('Calling initializeCorduit...');
      await initializeCorduit(configJson: jsonConfig);
      _activeProfileId = activeProfileId;
      _appliedConfigJson = jsonConfig;
      _ruleSetReport = report;
      _isInitialized = true;
      _ensureRuleSetTimer();
      debugPrint('VeloGuard initialized from active profile: $activeProfileId');
      notifyListeners();
    } catch (e, stackTrace) {
      debugPrint('Failed to initialize from active profile: $e');
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
    GeneralSettings generalSettings,
  ) async {
    final warnings = <String>[];
    final dnsSettings = await StorageService.instance.getDnsSettings();
    final report = await RuleProviderService.instance.prepare(
      profileId,
      configContent,
      onWarning: warnings.add,
    );
    final jsonConfig = ConfigConverter.convertClashYamlToJson(
      configContent,
      generalSettings: generalSettings,
      dnsSettings: dnsSettings,
      recursiveDnsAddress: _recursiveDnsAddress,
      ruleProviderPaths: report.paths,
      onWarning: warnings.add,
    );
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
  Future<bool> refreshRuleSets({bool force = false}) async {
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
      );
      _ruleSetReport = report;

      if (_isServiceRunning && jsonConfig != _appliedConfigJson) {
        await reloadCorduit(configJson: jsonConfig);
        _appliedConfigJson = jsonConfig;
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

  /// Rule sets are checked every 15 minutes; only the providers whose declared
  /// interval has elapsed actually hit the network, so the monthly cost of a
  /// daily set is one metadata read per tick.
  void _ensureRuleSetTimer() {
    _ruleSetTimer?.cancel();
    _ruleSetTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      refreshRuleSets();
    });
  }

  /// Bring the RecurseX front-end up when the DNS settings ask for local
  /// recursion, and remember the bound address so the next config
  /// conversion can point corduit at it.
  Future<void> _ensureRecursiveDns() async {
    try {
      final dnsSettings = await StorageService.instance.getDnsSettings();
      if (!dnsSettings.useRecursiveResolver) {
        await _stopRecursiveDns();
        return;
      }

      // Port 0 asks the OS for a free port, so the resolver never fights
      // with a system DNS service for 53.
      _recursiveDnsAddress = await startRecursiveDns(listen: '127.0.0.1:0');
      debugPrint(
        'RecurseX recursive resolver listening on $_recursiveDnsAddress',
      );
    } catch (e) {
      _recursiveDnsAddress = null;
      debugPrint('Failed to start the recursive resolver: $e');
    }
  }

  Future<void> _stopRecursiveDns() async {
    // Unconditional: the Rust side treats stopping a stopped front-end as a
    // no-op, and this way a half-initialised state cannot leak a listener.
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

  Future<bool> setProxyMode(ProxyMode mode) async {
    if (_proxyMode == mode) return true;

    final previousMode = _proxyMode;
    _proxyMode = mode;
    notifyListeners();

    try {
      final settings = await StorageService.instance.getGeneralSettings();
      await StorageService.instance.saveGeneralSettings(
        settings.copyWith(mode: mode.name),
      );
      if (NativeCoreService.instance.isReady) {
        final applied = await PlatformProxyService.instance.configureProxyMode(
          mode,
        );
        if (!applied) {
          throw StateError('Native router rejected ${mode.name} mode');
        }
      }
      return true;
    } catch (error) {
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
      _systemInfo = await getSystemInfo();
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
  Future<bool> startService() async {
    if (!NativeCoreService.instance.isReady) {
      debugPrint('Cannot start service: RustLib not initialized');
      return false;
    }

    _isLoading = true;
    notifyListeners();

    try {
      // Every start rebuilds the engine from the profile on disk: the config
      // may have changed (ports, mode, rule sets) since the last run, and
      // `initialize_corduit` is also what releases a previous instance.
      debugPrint('Re-initializing VeloGuard...');
      await _initializeFromActiveProfile();

      if (!_isInitialized) {
        debugPrint('Cannot start service: No profile selected');
        return false;
      }

      debugPrint('Starting VeloGuard proxy...');
      await startCorduit();

      // Set running state immediately after successful start
      _isServiceRunning = true;
      notifyListeners();

      // Wait a moment for the proxy to fully start
      await Future.delayed(const Duration(milliseconds: 300));

      // Verify the proxy is actually running
      try {
        final status = await getCorduitStatus();
        debugPrint('Proxy status after start: running=${status.running}');
        if (!status.running) {
          debugPrint('WARNING: Proxy reports not running after start!');
        }
        _proxyStatus = status;
      } catch (e) {
        debugPrint('Failed to get status after start: $e');
      }

      // Start status timer for periodic updates
      _startStatusTimer();

      // Windows: Auto enable system proxy if setting is enabled
      if (Platform.isWindows && _autoSystemProxy) {
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

      // Android: the proxy alone does not capture any traffic, the VPN has to
      // be up before the route to the proxy means anything.
      if (Platform.isAndroid) {
        if (!await _enableAndroidVpnWithRetry()) {
          debugPrint(
            'Failed to enable the VPN; the proxy stays up so the user can '
            'retry without restarting the service',
          );
        }
      }

      debugPrint('VeloGuard proxy started successfully');
      return true;
    } catch (e, stackTrace) {
      debugPrint('Failed to start service: $e');
      debugPrint('Stack trace: $stackTrace');
      _isServiceRunning = false;
      _isInitialized = false;
      return false;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> stopService() async {
    _isLoading = true;
    notifyListeners();

    try {
      debugPrint('Stopping VeloGuard service...');

      // Stop status timer first to prevent concurrent refresh during shutdown
      _stopStatusTimer();

      // Android: take the VPN down before the engine stops, so no packet
      // processor is left reading a closed descriptor.
      if (Platform.isAndroid || PlatformUtils.isOHOS) {
        await PlatformProxyService.instance.disableTunMode();
        debugPrint('VPN disabled automatically');

        // Wait for VPN to fully disconnect
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Windows: Disable system proxy if we enabled it
      if (Platform.isWindows && _systemProxyEnabledByUs) {
        debugPrint('Auto disabling system proxy...');
        await PlatformProxyService.instance.disableSystemProxy();
        _systemProxyEnabledByUs = false;
        debugPrint('System proxy disabled automatically');
      }

      await stopCorduit();
      await _stopRecursiveDns();
      _isServiceRunning = false;
      _isInitialized =
          false; // Mark as not initialized so we re-init on next start
      _proxyStatus = null;
      _trafficStats = null;
      _activeConnections.clear();
      _totalConnections = BigInt.zero;
      _activeConnectionCount = BigInt.zero;
      _totalUploadBytes = BigInt.zero;
      _totalDownloadBytes = BigInt.zero;
      _currentUploadSpeed = BigInt.zero;
      _currentDownloadSpeed = BigInt.zero;
      debugPrint('VeloGuard service stopped');
    } catch (e) {
      debugPrint('Failed to stop service: $e');
      _stopStatusTimer();
      _isServiceRunning = false;
      _isInitialized = false;
      _currentUploadSpeed = BigInt.zero;
      _currentDownloadSpeed = BigInt.zero;
      _activeConnections.clear();
      _totalConnections = BigInt.zero;
      _activeConnectionCount = BigInt.zero;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> restartService() async {
    debugPrint('Restarting VeloGuard service...');

    // Stop the service completely
    await stopService();

    // Wait for resources to be fully released
    await Future.delayed(const Duration(seconds: 2));

    await startService();
  }

  /// Brings the Android VPN up, retrying briefly: the platform needs a moment
  /// to release the VPN slot after a competing tunnel is torn down.
  Future<bool> _enableAndroidVpnWithRetry({int attempts = 3}) async {
    for (var attempt = 1; attempt <= attempts; attempt++) {
      if (await PlatformProxyService.instance.enableTunMode(mode: _proxyMode)) {
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

  Future<void> _refreshStatus() async {
    if (!NativeCoreService.instance.isReady) {
      debugPrint('Skipping status refresh: RustLib not initialized');
      return;
    }

    // Prevent concurrent refresh calls which can cause connection count issues
    if (_isRefreshing) {
      return;
    }
    _isRefreshing = true;

    try {
      _proxyStatus = await getCorduitStatus();
      _trafficStats = await getTrafficStats();

      // Only update isServiceRunning from proxyStatus if we got a valid response
      // and the service was not just started (to avoid race conditions)
      if (_proxyStatus != null) {
        // If proxy reports running, update our state
        // If proxy reports not running but we think it's running, log a warning
        // but don't immediately change state (could be a temporary issue)
        if (_proxyStatus!.running) {
          _isServiceRunning = true;
        } else if (_isServiceRunning && !_isLoading) {
          // Proxy reports not running but we think it is
          // This could be a real stop or a temporary issue
          debugPrint(
            'WARNING: Proxy reports not running, but _isServiceRunning is true',
          );
          // Only update if we're not in the middle of starting/stopping
          _isServiceRunning = false;
        }
      }

      // Use speed values directly from Rust tracker
      if (_trafficStats != null) {
        _currentUploadSpeed = _trafficStats!.uploadSpeed;
        _currentDownloadSpeed = _trafficStats!.downloadSpeed;
      }

      if (!_isServiceRunning) {
        _currentUploadSpeed = BigInt.zero;
        _currentDownloadSpeed = BigInt.zero;
      }

      // The connection list is only visible on its own screen and changes
      // slowly; polling it every third tick keeps the one-second refresh to
      // two bridge calls in the common case.
      _statusTicks++;
      if (_statusTicks % 3 == 0 || _activeConnections.isEmpty) {
        _activeConnections = await getActiveConnections();
      }

      // Get connection stats from tracker
      // Returns (total_count, total_upload, total_download, active_count) - all BigInt
      final stats = await getConnectionStats();
      _totalConnections = stats.$1;
      _totalUploadBytes = stats.$2;
      _totalDownloadBytes = stats.$3;
      _activeConnectionCount = stats.$4;

      // Auto-start status timer if service is running and timer not active
      if (_isServiceRunning && _statusTimer == null) {
        _startStatusTimer();
      }

      // Stop timer if service is down
      if (!_isServiceRunning && _statusTimer != null) {
        _stopStatusTimer();
      }

      notifyListeners();
    } catch (e) {
      debugPrint('Failed to refresh status: $e');
    } finally {
      _isRefreshing = false;
    }
  }

  Future<void> refreshStatus() async {
    await _refreshStatus();
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

  Future<void> loadConfiguration(String configJson) async {
    if (!NativeCoreService.instance.isReady) {
      debugPrint('Cannot load config: RustLib not initialized');
      return;
    }

    _isLoading = true;
    notifyListeners();

    try {
      await initializeCorduit(configJson: configJson);
      await _refreshStatus();
    } catch (e) {
      debugPrint('Failed to load configuration: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> reloadConfiguration(String configJson) async {
    if (!NativeCoreService.instance.isReady) {
      debugPrint('Cannot reload config: RustLib not initialized');
      return;
    }

    _isLoading = true;
    notifyListeners();

    try {
      await reloadCorduit(configJson: configJson);
      await _refreshStatus();
    } catch (e) {
      debugPrint('Failed to reload configuration: $e');
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
    // Use the new Rust API to close all connections at once
    try {
      await closeAllConnections();
      await _refreshStatus();
    } catch (e) {
      debugPrint('Failed to close all connections: $e');
      // Fallback to closing one by one
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
