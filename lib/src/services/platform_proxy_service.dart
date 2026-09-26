import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:arcadiaplus/src/rust/api.dart' as rust_api;
import 'package:arcadiaplus/src/utils/platform_utils.dart';

enum ProxyMode { global, rule, direct }

/// Owns the platform's own proxy and tunnel state.
///
/// Every switch in the app is a view of these three facts, and they are only
/// ever changed here: the app enabling the system proxy with the service, the
/// user flipping a switch, Android reporting a VPN it started, a routing mode
/// switch. Publishing each change is what keeps a switch from describing a
/// state the OS is not in — which is what happened when the service enabled
/// the system proxy on start-up and the network screen still said "off".
class PlatformProxyService extends ChangeNotifier {
  static final PlatformProxyService instance = PlatformProxyService._();
  PlatformProxyService._() {
    _setupMethodChannel();
  }

  static const MethodChannel _channel = MethodChannel('com.arcadiaplus/proxy');
  static const MethodChannel _ohosChannel = MethodChannel(
    'com.arcadiaplus/ohos_proxy',
  );

  bool _systemProxyEnabled = false;
  bool _tunModeEnabled = false;
  ProxyMode _currentProxyMode = ProxyMode.rule;
  int _vpnFd = -1;

  bool get systemProxyEnabled => _systemProxyEnabled;
  bool get tunModeEnabled => _tunModeEnabled;
  ProxyMode get currentProxyMode => _currentProxyMode;
  int get vpnFd => _vpnFd;
  int get androidVpnFd => _vpnFd;
  Function(bool isRunning)? onVpnStatusChanged;

  /// Records what the platform is doing now and tells the listeners.
  ///
  /// A no-op value does not notify: a mode switch touches the mode and the
  /// tunnel in one step, and rebuilding the UI for a value that did not move
  /// is exactly the kind of noise this class used to cause.
  void _publish({bool? systemProxy, bool? tunEnabled, ProxyMode? mode}) {
    var changed = false;
    if (systemProxy != null && systemProxy != _systemProxyEnabled) {
      _systemProxyEnabled = systemProxy;
      changed = true;
    }
    if (tunEnabled != null && tunEnabled != _tunModeEnabled) {
      _tunModeEnabled = tunEnabled;
      changed = true;
    }
    if (mode != null && mode != _currentProxyMode) {
      _currentProxyMode = mode;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  static int _runtimeModeValue(ProxyMode mode) => switch (mode) {
    ProxyMode.global => 1,
    ProxyMode.direct => 2,
    ProxyMode.rule => 3,
  };

  /// Applies a routing mode to the engine and, only when a tunnel is up, to
  /// the platform's own routing state.
  ///
  /// The engine mode is the authority on every platform: inbounds, the TUN
  /// netstack and the VPN all funnel their connections through one router, so
  /// a mode switch never needs the tunnel restarted.
  Future<bool> configureProxyMode(ProxyMode mode) async {
    try {
      _publish(mode: mode);
      await rust_api.setProxyMode(mode: _runtimeModeValue(mode));
      if (!_tunModeEnabled) return true;
      return await setProxyMode(mode);
    } catch (error) {
      debugPrint('Failed to configure proxy mode: $error');
      return false;
    }
  }

  void _setupMethodChannel() {
    debugPrint('PlatformProxyService: Setting up MethodChannel handlers');

    _channel.setMethodCallHandler((call) async {
      debugPrint('PlatformProxyService: Received ${call.method}');

      switch (call.method) {
        case 'vpnStatusChanged':
          if (call.arguments is Map) {
            final args = call.arguments as Map;
            final isRunning = args['isRunning'] as bool? ?? false;
            final fd = (args['fd'] as num?)?.toInt() ?? -1;
            _vpnFd = fd;
            _publish(tunEnabled: isRunning);
            onVpnStatusChanged?.call(isRunning);
          }
          return null;
        default:
          return null;
      }
    });

    _ohosChannel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'vpnStatusChanged':
          if (call.arguments is Map) {
            final args = call.arguments as Map;
            _vpnFd = (args['fd'] as num?)?.toInt() ?? -1;
            _publish(tunEnabled: args['isRunning'] as bool? ?? false);
            onVpnStatusChanged?.call(_tunModeEnabled);
          }
          return null;
        default:
          return null;
      }
    });

    debugPrint('PlatformProxyService: MethodChannel handlers set up');
  }

  /// Points the platform's proxy at the local mixed port.
  ///
  /// [httpPort] is the mixed port: it answers both plain HTTP and CONNECT,
  /// which is all a system proxy setting can express on every platform here.
  Future<bool> enableSystemProxy({
    required String host,
    required int httpPort,
    List<String> bypass = const [],
  }) async {
    try {
      if (Platform.isWindows) {
        return await _enableWindowsSystemProxy(host, httpPort, bypass);
      }
      if (Platform.isAndroid || PlatformUtils.isOHOS) {
        return false;
      }
      if (Platform.isMacOS) {
        return await _enableMacOSSystemProxy(host, httpPort, bypass);
      }
      if (Platform.isLinux) {
        return await _enableLinuxSystemProxy(host, httpPort, bypass);
      }
      return false;
    } catch (e) {
      debugPrint('Failed to enable system proxy: $e');
      return false;
    }
  }

  Future<bool> disableSystemProxy() async {
    try {
      if (Platform.isWindows) {
        return await _disableWindowsSystemProxy();
      }
      if (Platform.isAndroid || PlatformUtils.isOHOS) {
        return true;
      }
      if (Platform.isMacOS) {
        return await _disableMacOSSystemProxy();
      }
      if (Platform.isLinux) {
        return await _disableLinuxSystemProxy();
      }
      return false;
    } catch (e) {
      debugPrint('Failed to disable system proxy: $e');
      return false;
    }
  }

  /// Starts the tunnel.
  ///
  /// [allowLan] decides whether private (LAN) ranges are captured by the
  /// tunnel. With it off they are left to the system's own routing, so LAN
  /// traffic never enters the engine; with it on the tunnel captures them and
  /// the rules decide where they go.
  Future<bool> enableTunMode({
    ProxyMode mode = ProxyMode.rule,
    bool allowLan = true,
  }) async {
    try {
      if (Platform.isWindows) {
        return await _enableWindowsTun(mode);
      }
      if (Platform.isAndroid) {
        return await _enableAndroidVpn(mode: mode, allowLan: allowLan);
      }
      if (PlatformUtils.isOHOS) {
        return await _enableOhosVpn(mode: mode);
      }
      if (Platform.isMacOS || Platform.isLinux) {
        final status = await rust_api.enableTunModeWithMode(mode: mode.name);
        if (status.enabled) {
          _publish(tunEnabled: true, mode: mode);
        } else {
          _publish(tunEnabled: false);
          if (status.error case final error?) {
            debugPrint('Failed to enable TUN mode: $error');
          }
        }
        return status.enabled;
      }
      return false;
    } catch (e) {
      debugPrint('Failed to enable TUN mode: $e');
      return false;
    }
  }

  Future<bool> disableTunMode() async {
    try {
      if (Platform.isWindows) {
        return await _disableWindowsTun();
      }
      if (Platform.isAndroid) {
        return await _disableAndroidVpn();
      }
      if (PlatformUtils.isOHOS) {
        return await _disableOhosVpn();
      }
      if (Platform.isMacOS || Platform.isLinux) {
        final status = await rust_api.disableTunMode();
        _publish(tunEnabled: status.enabled);
        if (status.error case final error?) {
          debugPrint('Failed to disable TUN mode: $error');
          return false;
        }
        return !status.enabled;
      }
      return false;
    } catch (e) {
      debugPrint('Failed to disable TUN mode: $e');
      return false;
    }
  }

  /// Points WinINET at the local mixed port.
  ///
  /// The previous values are snapshotted first: disabling the proxy restores
  /// the user's own settings instead of clearing them. WinHTTP is deliberately
  /// left alone — it is machine-wide configuration that services and system
  /// components depend on, and hijacking it is not this app's business.
  ///
  /// The bypass list is written in WinINET's dialect, and the change is
  /// broadcast afterwards; see [expandBypassForGlobMatching] and
  /// [_broadcastWinInetChange] for why both are necessary.
  Future<bool> _enableWindowsSystemProxy(
    String host,
    int port,
    List<String> bypass,
  ) async {
    final endpointHost = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    final endpoint = '$endpointHost:$port';
    final entries = <String>[
      ...expandBypassForGlobMatching(bypass),
      // WinINET's own shorthand for "any host name without a dot".
      '<local>',
    ];
    final override = _uniquePreservingOrder(entries).join(';');

    try {
      await _snapshotWindowsProxySettings();
      // Order is the contract: the server and the bypass list land *before*
      // the switch is thrown. Written the other way round, a failure between
      // the writes leaves WinINET "enabled" with no server behind it —
      // Windows Settings then shows a switch that promises browsing and an
      // address box that cannot deliver it, which is exactly the
      // "the proxy is on but nothing works" report this ordering prevents.
      final serverApplied = [
        await _regAdd('ProxyServer', 'REG_SZ', endpoint),
        await _regAdd('ProxyOverride', 'REG_SZ', override),
      ];
      if (!serverApplied.every((write) => write)) {
        debugPrint('Windows system proxy server could not be written');
        _publish(systemProxy: await _readWindowsProxyEnabled());
        return false;
      }

      // Remembered so a refused switch write restores the machine instead of
      // leaving a half-applied configuration behind.
      final previousEnable =
          (await _regQuery('ProxyEnable'))?['value'] ?? '0x0';
      if (!await _regAdd('ProxyEnable', 'REG_DWORD', '1')) {
        debugPrint('Windows system proxy could not be switched on');
        await _regAdd('ProxyEnable', 'REG_DWORD', previousEnable);
        _publish(systemProxy: await _readWindowsProxyEnabled());
        return false;
      }
      _broadcastWinInetChange();
      _publish(systemProxy: true);
      return true;
    } catch (e) {
      debugPrint('Windows proxy error: $e');
      return false;
    }
  }

  Future<bool> _disableWindowsSystemProxy() async {
    try {
      if (await _restoreWindowsProxySettings()) {
        // The user's own settings are back in force. What that leaves enabled
        // is theirs, not ours, so the call succeeded either way.
        _broadcastWinInetChange();
        _publish(systemProxy: await _readWindowsProxyEnabled());
        return true;
      }

      // No usable snapshot: switch the proxy off rather than leaving the
      // machine pointed at a port nobody listens on. The user's own
      // ProxyServer value stays in the registry, just disabled.
      await _regAdd('ProxyEnable', 'REG_DWORD', '0');
      _broadcastWinInetChange();
      final enabled = await _readWindowsProxyEnabled();
      _publish(systemProxy: enabled);
      return !enabled;
    } catch (e) {
      debugPrint('Windows proxy disable error: $e');
      _publish(systemProxy: false);
      return false;
    }
  }

  /// Creates the adapter only when the process can actually do it.
  ///
  /// Wintun creates a kernel adapter, which needs an elevated token. The check
  /// happens here so a refusal becomes an instruction — "restart as
  /// administrator" — instead of an `Access is denied` code relayed from
  /// `Adapter::create`.
  Future<bool> _enableWindowsTun(ProxyMode mode) async {
    try {
      if (!await isProcessElevated()) {
        _lastTunError =
            'Administrator privileges are required to create the network '
            'adapter. Restart ArcadiaPlus as administrator and try again.';
        debugPrint('Windows TUN error: $_lastTunError');
        _publish(tunEnabled: false);
        return false;
      }
      await rust_api.ensureWintunDll();
      final status = await rust_api.enableTunModeWithMode(mode: mode.name);
      if (status.enabled) {
        _lastTunError = null;
        _publish(tunEnabled: true, mode: mode);
      } else {
        _lastTunError = status.error;
        _publish(tunEnabled: false);
        if (status.error case final error?) {
          debugPrint('Windows TUN error: $error');
        }
      }
      return status.enabled;
    } catch (e) {
      _lastTunError = '$e';
      debugPrint('Windows TUN error: $e');
      return false;
    }
  }

  Future<bool> _disableWindowsTun() async {
    try {
      final status = await rust_api.disableTunMode();
      _publish(tunEnabled: status.enabled);
      return !status.enabled;
    } catch (e) {
      debugPrint('Windows TUN disable error: $e');
      _publish(tunEnabled: false);
      return true;
    }
  }

  /// Set Windows proxy mode at runtime
  /// mode: ProxyMode.rule, ProxyMode.global, or ProxyMode.direct
  Future<bool> setWindowsProxyMode(ProxyMode mode) async {
    if (!Platform.isWindows) return false;
    try {
      final result = await rust_api.setWindowsProxyMode(mode: mode.name);
      if (result) {
        _publish(mode: mode);
        debugPrint('Windows proxy mode set to ${mode.name}');
      }
      return result;
    } catch (e) {
      // The engine refuses `global` while a TUN route manager is up but not
      // carrying global routes; rebuilding the tunnel is the documented way
      // into that state, and it is what the user asked for by picking global
      // while connected.
      if (mode == ProxyMode.global && _tunModeEnabled) {
        debugPrint('Entering global mode through the TUN route table: $e');
        return enableWindowsTunWithMode(mode);
      }
      debugPrint('Failed to set Windows proxy mode: $e');
      return false;
    }
  }

  /// Get current Windows proxy mode
  Future<String> getWindowsProxyMode() async {
    if (!Platform.isWindows) return _currentProxyMode.name;
    try {
      return await rust_api.getWindowsProxyModeStr();
    } catch (e) {
      return _currentProxyMode.name;
    }
  }

  /// Windows TUN counters as `(packetsReceived, packetsSent, bytesReceived,
  /// bytesSent, tcpConnections, udpSessions)`.
  Future<(int, int, int, int, int, int)> getWindowsTunStats() async {
    if (!Platform.isWindows) return (0, 0, 0, 0, 0, 0);
    try {
      final stats = await rust_api.getWindowsTunStats();
      return (
        stats.$1.toInt(),
        stats.$2.toInt(),
        stats.$3.toInt(),
        stats.$4.toInt(),
        stats.$5.toInt(),
        stats.$6.toInt(),
      );
    } catch (e) {
      debugPrint('Failed to get Windows TUN stats: $e');
      return (0, 0, 0, 0, 0, 0);
    }
  }

  /// Enable Windows TUN mode with specific proxy mode
  Future<bool> enableWindowsTunWithMode(ProxyMode mode) async {
    if (!Platform.isWindows) return false;
    try {
      await rust_api.ensureWintunDll();
      final status = await rust_api.enableTunModeWithMode(mode: mode.name);
      if (status.enabled) {
        _publish(tunEnabled: true, mode: mode);
      } else {
        _publish(tunEnabled: false);
        if (status.error case final error?) {
          debugPrint('Windows TUN error: $error');
        }
      }
      return status.enabled;
    } catch (e) {
      debugPrint('Windows TUN error: $e');
      return false;
    }
  }

  Future<bool> _enableAndroidVpn({
    ProxyMode mode = ProxyMode.rule,
    bool allowLan = true,
  }) async {
    try {
      debugPrint('=== _enableAndroidVpn: Starting with mode=$mode ===');

      // Check if another VPN is active - we will attempt to take over
      final otherVpnActive = await isOtherVpnActive();
      if (otherVpnActive) {
        debugPrint(
          '_enableAndroidVpn: Another VPN is active - will attempt to take over',
        );
      }

      // If already running, stop first
      if (_tunModeEnabled || _vpnFd >= 0) {
        debugPrint('_enableAndroidVpn: VPN already enabled, stopping first...');
        await _disableAndroidVpn();
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      // Reset state
      _vpnFd = -1;
      _publish(tunEnabled: false);

      // Try to reset VPN state (for recovery after app reinstall)
      try {
        await _channel.invokeMethod('resetVpnState');
        debugPrint('_enableAndroidVpn: VPN state reset successfully');
      } catch (e) {
        debugPrint('_enableAndroidVpn: resetVpnState not available: $e');
      }

      debugPrint('_enableAndroidVpn: Calling startVpn via MethodChannel...');

      // Call Android side to start VPN, returns fd synchronously
      final dynamic result;
      try {
        result = await _channel.invokeMethod('startVpn', {
          'mode': mode.name,
          'allowLan': allowLan,
        });
      } on PlatformException catch (e) {
        debugPrint(
          '_enableAndroidVpn: PlatformException during startVpn: ${e.code} - ${e.message}',
        );
        return false;
      }

      debugPrint(
        '_enableAndroidVpn: startVpn result=$result (type: ${result.runtimeType})',
      );

      int fd = -1;
      String? errorMsg;

      if (result is Map) {
        final success = result['success'] as bool? ?? false;
        fd = (result['fd'] as num?)?.toInt() ?? -1;
        errorMsg = result['error'] as String?;

        if (!success || fd < 0) {
          debugPrint(
            '_enableAndroidVpn: Android VPN start failed - success=$success, fd=$fd, error=$errorMsg',
          );
          // Return false, let caller show appropriate error message
          return false;
        }

        _vpnFd = fd;
        debugPrint('=== _enableAndroidVpn: Got VPN fd=$fd from Android ===');
      } else if (result == true) {
        // Compatible with old return format, try to get fd
        debugPrint('_enableAndroidVpn: Legacy result format, fetching fd...');
        try {
          fd = await _channel.invokeMethod('getVpnFd') as int? ?? -1;
        } catch (e) {
          debugPrint('_enableAndroidVpn: Failed to get VPN fd: $e');
          return false;
        }

        if (fd < 0) {
          debugPrint(
            '_enableAndroidVpn: startVpn returned true but fd is invalid ($fd)',
          );
          return false;
        }
        _vpnFd = fd;
        debugPrint('=== _enableAndroidVpn: Got VPN fd=$fd (via getVpnFd) ===');
      } else if (result == false) {
        debugPrint('_enableAndroidVpn: startVpn returned false');
        return false;
      } else {
        debugPrint(
          '_enableAndroidVpn: startVpn returned unexpected result type: ${result.runtimeType}',
        );
        return false;
      }

      // Set VPN fd in Rust layer and start processing
      try {
        debugPrint(
          '_enableAndroidVpn: Setting VPN fd=$_vpnFd in Rust layer...',
        );
        rust_api.setAndroidVpnFd(fd: _vpnFd);

        debugPrint('_enableAndroidVpn: Setting proxy mode to ${mode.name}...');
        rust_api.setAndroidProxyMode(mode: mode.name);

        debugPrint(
          '_enableAndroidVpn: Starting Android VPN packet processing in Rust...',
        );
        final vpnStarted = await rust_api.startAndroidVpn();
        debugPrint(
          '_enableAndroidVpn: Rust startAndroidVpn returned: $vpnStarted',
        );

        if (!vpnStarted) {
          debugPrint(
            '_enableAndroidVpn: Rust VPN packet processing failed to start',
          );
          // Cleanup Android side VPN
          try {
            await _channel.invokeMethod('stopVpn');
          } catch (e) {
            debugPrint(
              '_enableAndroidVpn: Failed to stop Android VPN after Rust failure: $e',
            );
          }
          _vpnFd = -1;
          return false;
        }
      } catch (e, stackTrace) {
        debugPrint('_enableAndroidVpn: Failed to start Rust VPN: $e');
        debugPrint('Stack trace: $stackTrace');
        // Cleanup Android side VPN
        try {
          await _channel.invokeMethod('stopVpn');
        } catch (_) {}
        _vpnFd = -1;
        return false;
      }

      _publish(tunEnabled: true, mode: mode);
      debugPrint(
        '=== _enableAndroidVpn: VPN enabled successfully, fd=$_vpnFd, mode=$mode ===',
      );
      return true;
    } on PlatformException catch (e) {
      debugPrint(
        '_enableAndroidVpn: PlatformException: ${e.code} - ${e.message}',
      );
      _vpnFd = -1;
      _publish(tunEnabled: false);
      return false;
    } catch (e, stackTrace) {
      debugPrint('_enableAndroidVpn: Unexpected error: $e');
      debugPrint('Stack trace: $stackTrace');
      _vpnFd = -1;
      _publish(tunEnabled: false);
      return false;
    }
  }

  Future<bool> _disableAndroidVpn() async {
    try {
      debugPrint('=== _disableAndroidVpn: Starting VPN shutdown ===');

      // First cleanup Rust layer - stop packet processing
      try {
        debugPrint('_disableAndroidVpn: Stopping Rust VPN processing...');
        await rust_api.stopAndroidVpn();
        rust_api.clearAndroidVpnFd();
        debugPrint('_disableAndroidVpn: Rust VPN state cleared');
      } catch (e) {
        debugPrint('_disableAndroidVpn: Failed to cleanup Rust VPN state: $e');
      }

      // Then stop Android VPN service
      debugPrint('_disableAndroidVpn: Stopping Android VPN service...');
      await _channel.invokeMethod('stopVpn');
      debugPrint('_disableAndroidVpn: Android VPN service stopped');

      _vpnFd = -1;
      _publish(tunEnabled: false);

      // Wait for VPN to fully disconnect
      await Future.delayed(const Duration(milliseconds: 500));

      // Verify VPN is actually stopped
      try {
        final isRunning =
            await _channel.invokeMethod('isVpnRunning') as bool? ?? false;
        if (isRunning) {
          debugPrint(
            '_disableAndroidVpn: WARNING - VPN still running after stop, forcing reset...',
          );
          await _channel.invokeMethod('resetVpnState');
          await Future.delayed(const Duration(milliseconds: 300));
        }
      } catch (e) {
        debugPrint('_disableAndroidVpn: Error checking VPN status: $e');
      }

      debugPrint('=== _disableAndroidVpn: VPN shutdown complete ===');
      return true;
    } on PlatformException catch (e) {
      debugPrint('_disableAndroidVpn: PlatformException: ${e.message}');
      _vpnFd = -1;
      _publish(tunEnabled: false);
      return false;
    }
  }

  /// The reason the last TUN switch attempt reported failure, or `null` when
  /// the last attempt succeeded. The network screen shows it instead of a
  /// generic "failed", because "restart as administrator" is actionable and
  /// "could not be started" is not.
  String? get lastTunError => _lastTunError;
  String? _lastTunError;

  String? _ohosConfigPath;
  String? _ohosGeoipPath;
  String? _ohosLogPath;

  /// Records the paths the HarmonyOS extension reads when it runs the engine.
  ///
  /// The extension lives in its own process — only the sandbox is shared — so
  /// the generated config, the unpacked GeoIP database and the engine log
  /// reach it as paths carried in the start request, not as objects in memory.
  void prepareOhosEngine({
    required String configPath,
    String? geoipPath,
    String? logPath,
  }) {
    _ohosConfigPath = configPath;
    _ohosGeoipPath = geoipPath;
    _ohosLogPath = logPath;
  }

  bool? _processElevated;

  /// Whether this process holds an elevated (administrator) token.
  ///
  /// Asked at most once: the answer cannot change while the process lives, and
  /// the answer is a `powershell` round-trip. Always `false` off Windows.
  Future<bool> isProcessElevated() async {
    if (!Platform.isWindows) return false;
    final cached = _processElevated;
    if (cached != null) return cached;
    try {
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '([Security.Principal.WindowsPrincipal]'
            '[Security.Principal.WindowsIdentity]::GetCurrent())'
            '.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)',
      ]);
      final elevated =
          result.exitCode == 0 &&
          result.stdout.toString().trim().toLowerCase() == 'true';
      _processElevated = elevated;
      return elevated;
    } catch (e) {
      debugPrint('Failed to read the elevation state: $e');
      return false;
    }
  }

  /// Relaunch the app with an elevated token so the user can retry the TUN
  /// switch.
  ///
  /// Returns false when the launch was refused (a declined UAC prompt or a
  /// policy block); the caller reports that rather than pretending a new
  /// instance is coming up.
  Future<bool> relaunchAsAdministrator() async {
    if (!Platform.isWindows) return false;
    try {
      final executable = Platform.resolvedExecutable.replaceAll("'", "''");
      final result = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        "Start-Process -FilePath '$executable' -Verb RunAs",
      ]);
      if (result.exitCode != 0) {
        debugPrint('Elevation was refused: ${result.stderr}');
        return false;
      }
      _processElevated = true;
      return true;
    } catch (e) {
      debugPrint('Failed to relaunch as administrator: $e');
      return false;
    }
  }

  Future<bool> _enableOhosVpn({ProxyMode mode = ProxyMode.rule}) async {
    try {
      debugPrint('_enableOhosVpn: Starting with mode=$mode');

      if (_tunModeEnabled || _vpnFd >= 0) {
        await _disableOhosVpn();
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      _vpnFd = -1;
      _publish(tunEnabled: false);

      // The tunnel lives in the VpnExtensionAbility process: it is the only
      // place allowed to create the adapter and the tun fd the engine reads,
      // and it is where the packet path runs. The request carries the routing
      // mode plus the paths of the staged config, GeoIP database and log —
      // the extension shares the sandbox but not this process's memory.
      final configPath = _ohosConfigPath;
      if (configPath == null) {
        debugPrint(
          '_enableOhosVpn: no engine config was staged for the extension',
        );
        return false;
      }
      final result = await _ohosChannel.invokeMethod<Map<Object?, Object?>>(
        'startVpn',
        {
          'mode': mode.name,
          'configPath': configPath,
          if (_ohosGeoipPath != null) 'geoipPath': _ohosGeoipPath,
          if (_ohosLogPath != null) 'logPath': _ohosLogPath,
        },
      );
      final success = result?['success'] == true;
      if (!success) {
        final error = result?['error']?.toString();
        if (error != null && error.isNotEmpty) {
          debugPrint('_enableOhosVpn: $error');
        }
        return false;
      }

      _publish(tunEnabled: true, mode: mode);
      debugPrint('_enableOhosVpn: VPN enabled successfully');
      return true;
    } on PlatformException catch (e) {
      debugPrint('_enableOhosVpn: ${e.code}: ${e.message}');
      _vpnFd = -1;
      _publish(tunEnabled: false);
      return false;
    }
  }

  Future<bool> _disableOhosVpn() async {
    try {
      final result = await _ohosChannel.invokeMethod<Map<Object?, Object?>>(
        'stopVpn',
      );
      _vpnFd = -1;
      _publish(tunEnabled: false);
      final success = result?['success'] == true;
      if (!success) {
        final error = result?['error']?.toString();
        debugPrint('OHOS VPN stop reported: $error');
      }
      return success;
    } on PlatformException catch (e) {
      debugPrint('OHOS VPN disable error: ${e.message}');
      return false;
    }
  }

  Future<bool> setOhosProxyMode(ProxyMode mode) async {
    if (!PlatformUtils.isOHOS) return false;
    try {
      final result = await _ohosChannel.invokeMethod('setProxyMode', {
        'mode': mode.name,
      });
      final accepted = result == true;
      // The extension owns the tunnel's mode; this process' engine mirrors it
      // so the UI keeps answering stats and rules from the mode it displays.
      // A failure of that local mirror is reported but must not mask a switch
      // the extension already accepted.
      try {
        await rust_api.setAndroidProxyMode(mode: mode.name);
      } catch (e) {
        debugPrint('OHOS: the local engine did not take mode $mode: $e');
      }
      _publish(mode: mode);
      return accepted;
    } catch (e) {
      debugPrint('Failed to set OHOS proxy mode: $e');
      return false;
    }
  }

  /// Hands a mode switch to the platform that owns the tunnel.
  ///
  /// Windows is the only platform where the route table depends on the mode
  /// (global mode routes everything through the adapter); Android, HarmonyOS
  /// and the desktop tunnels read the mode from the engine at dial time, so
  /// they only record it. The engine itself was already switched by
  /// [configureProxyMode].
  Future<bool> setProxyMode(ProxyMode mode) async {
    if (Platform.isAndroid) {
      return setAndroidProxyMode(mode);
    }
    if (PlatformUtils.isOHOS) {
      return setOhosProxyMode(mode);
    }
    if (Platform.isWindows) {
      return setWindowsProxyMode(mode);
    }
    _publish(mode: mode);
    return true;
  }

  Future<bool> setAndroidProxyMode(ProxyMode mode) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod('setProxyMode', {
        'mode': mode.name,
      });
      if (result == true) {
        // The engine first, then the published state: a mode the engine
        // refused must not be shown as applied.
        await rust_api.setAndroidProxyMode(mode: mode.name);
        _publish(mode: mode);
      }
      return result == true;
    } catch (e) {
      debugPrint('Failed to set proxy mode: $e');
      return false;
    }
  }

  /// Points every macOS network service at the local mixed port.
  ///
  /// The bypass list is part of the platform's proxy configuration here too,
  /// and the previous lists are snapshotted first for the same reason they are
  /// on Windows.
  Future<bool> _enableMacOSSystemProxy(
    String host,
    int port,
    List<String> bypass,
  ) async {
    try {
      final services = await _macOSNetworkServices();
      if (services.isEmpty) {
        debugPrint('macOS proxy error: no network services to configure');
        return false;
      }
      await _snapshotMacOSBypassDomains(services);
      final entries = expandBypassForGlobMatching(bypass);
      var applied = true;
      for (final service in services) {
        applied =
            await _macOSProxyCommand([
              '-setwebproxy',
              service,
              host,
              '$port',
            ]) &&
            applied;
        applied =
            await _macOSProxyCommand([
              '-setsecurewebproxy',
              service,
              host,
              '$port',
            ]) &&
            applied;
        applied =
            await _macOSProxyCommand([
              '-setsocksfirewallproxy',
              service,
              host,
              '$port',
            ]) &&
            applied;
        applied = await _macOSSetBypassDomains(service, entries) && applied;
      }
      _publish(systemProxy: applied);
      return applied;
    } catch (e) {
      debugPrint('macOS proxy error: $e');
      return false;
    }
  }

  Future<bool> _disableMacOSSystemProxy() async {
    try {
      final services = await _macOSNetworkServices();
      var applied = true;
      for (final service in services) {
        applied =
            await _macOSProxyCommand(['-setwebproxystate', service, 'off']) &&
            applied;
        applied =
            await _macOSProxyCommand([
              '-setsecurewebproxystate',
              service,
              'off',
            ]) &&
            applied;
        applied =
            await _macOSProxyCommand([
              '-setsocksfirewallproxystate',
              service,
              'off',
            ]) &&
            applied;
      }
      // Best effort: the bypass list is secondary state, and a snapshot that
      // cannot be replayed must not make "the proxy is off now" report as a
      // failure the user has to act on.
      if (!await _restoreMacOSBypassDomains()) {
        debugPrint('macOS bypass domains: nothing recorded to restore');
      }
      _publish(systemProxy: await _macOSAnyProxyEnabled(services));
      return applied;
    } catch (e) {
      debugPrint('macOS proxy disable error: $e');
      return false;
    }
  }

  /// Whether any of the proxies this app configures is enabled on [service].
  ///
  /// Read from `networksetup` rather than remembered: a restart, or a change
  /// made in System Settings, has to show up on the switch as what it is.
  Future<bool> _macOSAnyProxyEnabled(List<String> services) async {
    for (final service in services) {
      for (final verb in const [
        '-getwebproxy',
        '-getsecurewebproxy',
        '-getsocksfirewallproxy',
      ]) {
        final result = await Process.run('networksetup', [verb, service]);
        if (result.exitCode != 0) continue;
        final match = RegExp(
          r'^Enabled:\s*(\w+)\s*$',
          multiLine: true,
        ).firstMatch(result.stdout.toString());
        if (match?.group(1)?.toLowerCase() == 'yes') return true;
      }
    }
    return false;
  }

  /// Whether any enabled macOS proxy targets [port].
  Future<bool> _macOSProxyTargets(List<String> services, int port) async {
    for (final service in services) {
      for (final verb in const [
        '-getwebproxy',
        '-getsecurewebproxy',
        '-getsocksfirewallproxy',
      ]) {
        final result = await Process.run('networksetup', [verb, service]);
        if (result.exitCode != 0) continue;
        final output = result.stdout.toString();
        final enabled = RegExp(
          r'^Enabled:\s*(\w+)\s*$',
          multiLine: true,
        ).firstMatch(output)?.group(1);
        if (enabled?.toLowerCase() != 'yes') continue;
        final portValue = RegExp(
          r'^Port:\s*(\d+)\s*$',
          multiLine: true,
        ).firstMatch(output)?.group(1);
        if (portValue == '$port') return true;
      }
    }
    return false;
  }

  /// Writes a bypass list onto [service].
  ///
  /// `networksetup` takes the entries as arguments, and an empty list is not
  /// "no arguments" — a single empty string is what clears it.
  Future<bool> _macOSSetBypassDomains(String service, List<String> domains) {
    return _macOSProxyCommand([
      '-setproxybypassdomains',
      service,
      ...domains.isEmpty ? const [''] : domains,
    ]);
  }

  /// The bypass domains [service] currently has. `null` when the tool could
  /// not be asked, which is different from "none configured".
  Future<List<String>?> _macOSBypassDomains(String service) async {
    final result = await Process.run('networksetup', [
      '-getproxybypassdomains',
      service,
    ]);
    if (result.exitCode != 0) return null;

    final domains = <String>[];
    for (final line in result.stdout.toString().split('\n')) {
      final entry = line.trim();
      // Skip the `<service> bypass domains:` header and the prose
      // `networksetup` prints instead of an empty list.
      if (entry.isEmpty ||
          entry.endsWith(':') ||
          entry.toLowerCase().contains('bypass domains')) {
        continue;
      }
      domains.add(entry);
    }
    return domains;
  }

  Future<File> _macOSProxySnapshotFile() async {
    final support = await getApplicationSupportDirectory();
    return File(
      '${support.path}${Platform.pathSeparator}macos-proxy-snapshot.json',
    );
  }

  /// Records the bypass lists before this app changes them. An existing
  /// snapshot is kept, so a second enable cannot overwrite the user's original
  /// lists with values this app wrote earlier.
  Future<void> _snapshotMacOSBypassDomains(List<String> services) async {
    final file = await _macOSProxySnapshotFile();
    if (file.existsSync()) return;

    final snapshot = <String, List<String>>{};
    for (final service in services) {
      final domains = await _macOSBypassDomains(service);
      if (domains != null) snapshot[service] = domains;
    }
    await file.writeAsString(jsonEncode(snapshot), flush: true);
  }

  /// Puts the recorded bypass lists back and drops the snapshot. Returns false
  /// when there was no snapshot to replay.
  Future<bool> _restoreMacOSBypassDomains() async {
    final file = await _macOSProxySnapshotFile();
    if (!file.existsSync()) return false;

    final Object? decoded;
    try {
      decoded = jsonDecode(await file.readAsString());
    } catch (e) {
      debugPrint('macOS bypass snapshot is malformed; clearing it: $e');
      await file.delete();
      return false;
    }
    if (decoded is! Map) {
      debugPrint('macOS bypass snapshot is malformed; clearing it');
      await file.delete();
      return false;
    }

    var restored = true;
    for (final service in decoded.keys) {
      final domains =
          (decoded[service] as List<dynamic>?)
              ?.map((entry) => entry.toString())
              .toList() ??
          const <String>[];
      restored =
          await _macOSSetBypassDomains(service.toString(), domains) && restored;
    }
    if (restored) {
      await file.delete();
    } else {
      debugPrint('macOS bypass domains could not be fully restored');
    }
    return restored;
  }

  Future<List<String>> _macOSNetworkServices() async {
    final result = await Process.run('networksetup', [
      '-listallnetworkservices',
    ]);
    if (result.exitCode != 0) {
      debugPrint('networksetup failed: ${result.stderr}');
      return const [];
    }
    return result.stdout
        .toString()
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty && !line.startsWith('*'))
        .toList(growable: false);
  }

  Future<bool> _macOSProxyCommand(List<String> arguments) async {
    final result = await Process.run('networksetup', arguments);
    if (result.exitCode != 0) {
      debugPrint('networksetup ${arguments.first} failed: ${result.stderr}');
      return false;
    }
    return true;
  }

  /// Configures GNOME's proxy through gsettings.
  ///
  /// Every call is checked: `gsettings` exits non-zero on a desktop without
  /// the schema (KDE, headless), and reporting success there would leave the
  /// UI claiming a system proxy that does not exist.
  ///
  /// `ignore-hosts` takes the canonical bypass form as it is, CIDR blocks
  /// included — that is how GNOME spells its own default `127.0.0.0/8` — so
  /// nothing is expanded here.
  Future<bool> _enableLinuxSystemProxy(
    String host,
    int port,
    List<String> bypass,
  ) async {
    try {
      final ignoreHosts = <String>{
        'localhost',
        '127.0.0.0/8',
        '::1',
        ...bypass,
      }.toList(growable: false);

      final commands = <List<String>>[
        ['set', 'org.gnome.system.proxy', 'mode', 'manual'],
        ['set', 'org.gnome.system.proxy.http', 'host', host],
        ['set', 'org.gnome.system.proxy.http', 'port', '$port'],
        ['set', 'org.gnome.system.proxy.https', 'host', host],
        ['set', 'org.gnome.system.proxy.https', 'port', '$port'],
        ['set', 'org.gnome.system.proxy.socks', 'host', host],
        ['set', 'org.gnome.system.proxy.socks', 'port', '$port'],
        [
          'set',
          'org.gnome.system.proxy',
          'ignore-hosts',
          _gvariantArray(ignoreHosts),
        ],
      ];

      for (final command in commands) {
        if (!await _runGsettings(command)) {
          return false;
        }
      }
      _publish(systemProxy: true);
      return true;
    } catch (e) {
      debugPrint('Linux proxy error: $e');
      return false;
    }
  }

  Future<bool> _disableLinuxSystemProxy() async {
    try {
      final applied = await _runGsettings([
        'set',
        'org.gnome.system.proxy',
        'mode',
        'none',
      ]);
      _publish(systemProxy: !applied);
      return applied;
    } catch (e) {
      debugPrint('Linux proxy disable error: $e');
      return false;
    }
  }

  Future<bool> _runGsettings(List<String> arguments) async {
    try {
      final result = await Process.run('gsettings', arguments);
      if (result.exitCode != 0) {
        debugPrint(
          'gsettings ${arguments.take(3).join(' ')} failed: ${result.stderr}',
        );
        return false;
      }
      return true;
    } on ProcessException catch (error) {
      debugPrint('gsettings is unavailable: $error');
      return false;
    }
  }

  /// Whether GNOME's HTTP proxy port is the one this app listens on.
  Future<bool> _linuxProxyTargets(int port) async {
    final result = await Process.run('gsettings', [
      'get',
      'org.gnome.system.proxy.http',
      'port',
    ]);
    if (result.exitCode != 0) return false;
    return result.stdout.toString().trim() == '$port';
  }

  /// Builds the GVariant array literal `gsettings set` expects.
  String _gvariantArray(List<String> values) {
    final escaped = values
        .map((value) {
          final quoted = value.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
          return "'$quoted'";
        })
        .join(', ');
    return '[$escaped]';
  }

  /// Reads the platform's own system-proxy state, so the UI can reflect what
  /// is actually configured rather than what this process once believed.
  ///
  /// Every platform answers this from its own configuration — Windows from
  /// WinINET, macOS from each network service, Linux from GNOME — because the
  /// state outlives this process: a restart, or a change made in the system's
  /// own settings, must show up as what it is.
  Future<bool> checkSystemProxyStatus() async {
    try {
      final bool enabled;
      if (Platform.isWindows) {
        enabled = await _readWindowsProxyEnabled();
      } else if (Platform.isMacOS) {
        enabled = await _macOSAnyProxyEnabled(await _macOSNetworkServices());
      } else if (Platform.isLinux) {
        final result = await Process.run('gsettings', [
          'get',
          'org.gnome.system.proxy',
          'mode',
        ]);
        enabled =
            result.exitCode == 0 &&
            result.stdout.toString().trim().replaceAll("'", '') == 'manual';
      } else {
        return _systemProxyEnabled;
      }
      _publish(systemProxy: enabled);
      return enabled;
    } catch (e) {
      debugPrint('Failed to read system proxy state: $e');
      return false;
    }
  }

  Future<bool> checkTunModeStatus() async {
    try {
      if (Platform.isAndroid) {
        final isRunning =
            await _channel.invokeMethod('isVpnRunning') as bool? ?? false;
        if (isRunning) {
          _vpnFd = await _channel.invokeMethod('getVpnFd') as int? ?? -1;
        }
        _publish(tunEnabled: isRunning);
        return isRunning;
      }
      if (PlatformUtils.isOHOS) {
        final result = await _ohosChannel.invokeMethod('isVpnRunning');
        _publish(tunEnabled: result == true);
        return result == true;
      }
      final status = await rust_api.getTunStatus();
      _publish(tunEnabled: status.enabled);
      return status.enabled;
    } catch (e) {
      debugPrint('Failed to check TUN status: $e');
      return false;
    }
  }

  /// Whether the platform's proxy is currently pointed at one of this app's
  /// listening ports.
  ///
  /// This is what decides whether the proxy may be switched off together with
  /// the service: one pointing at a closed port takes the machine's
  /// networking down with it, while one somebody else configured is none of
  /// this app's business.
  Future<bool> isSystemProxyPointingAt(int port) async {
    try {
      if (Platform.isWindows) return await _windowsProxyTargets(port);
      if (Platform.isMacOS) {
        return await _macOSProxyTargets(await _macOSNetworkServices(), port);
      }
      if (Platform.isLinux) return await _linuxProxyTargets(port);
      return false;
    } catch (e) {
      debugPrint('Failed to inspect the system proxy target: $e');
      return false;
    }
  }

  /// Check if another VPN app is currently active (Android only)
  /// Returns true if another VPN is running and blocking our VPN
  Future<bool> isOtherVpnActive() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod('isOtherVpnActive');
      return result == true;
    } catch (e) {
      debugPrint('Failed to check if other VPN is active: $e');
      return false;
    }
  }

  Future<bool> openUwpLoopbackUtility() async {
    if (!Platform.isWindows) return false;
    try {
      return await rust_api.openUwpLoopbackUtility();
    } catch (e) {
      debugPrint('Failed to open UWP loopback utility: $e');
      return false;
    }
  }

  // ==================== Bypass list dialects ====================

  /// The most wildcard patterns one IPv4 block may be expanded into.
  ///
  /// A private range needs a handful (`172.16.0.0/12` needs sixteen); anything
  /// that would need more is user input the write path cannot serve, and it is
  /// reported instead of being written as a pattern that matches the wrong
  /// addresses.
  static const int _maxBypassExpansion = 64;

  static final RegExp _ipv4Block = RegExp(
    r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})/(\d{1,2})$',
  );

  /// Renders the canonical bypass list for platforms whose proxy setting
  /// matches entries as plain strings.
  ///
  /// WinINET and `networksetup` have no notion of a CIDR block: written
  /// verbatim, `192.168.0.0/16` is a string that matches nothing, which is
  /// exactly how the private ranges end up tunnelled even though they are
  /// configured. Host names, `*.suffix` patterns and literals like `::1` pass
  /// through untouched; a block becomes the wildcard patterns covering the
  /// same addresses.
  static List<String> expandBypassForGlobMatching(List<String> canonical) {
    final expanded = <String>[];
    for (final rawEntry in canonical) {
      final entry = rawEntry.trim();
      if (entry.isEmpty) continue;

      final match = _ipv4Block.firstMatch(entry);
      if (match == null) {
        _addUnique(expanded, entry);
        continue;
      }

      final octets = [
        for (var index = 1; index <= 4; index++) int.parse(match.group(index)!),
      ];
      final prefix = int.parse(match.group(5)!);
      if (octets.any((octet) => octet > 255) || prefix > 32) {
        // Not a block after all; take the entry at face value.
        _addUnique(expanded, entry);
        continue;
      }

      final patterns = _ipv4BlockPatterns(octets, prefix);
      if (patterns == null) {
        debugPrint(
          'Bypass entry "$entry" has no wildcard equivalent and was not '
          'applied to the platform proxy',
        );
        continue;
      }
      for (final pattern in patterns) {
        _addUnique(expanded, pattern);
      }
    }
    return expanded;
  }

  /// The wildcard patterns covering exactly the addresses of one IPv4 block,
  /// or `null` when no exact cover exists.
  ///
  /// `10.0.0.0/8` and `192.168.0.0/16` fall on octet boundaries and become
  /// `10.*` and `192.168.*`. `172.16.0.0/12` straddles one: the addresses run
  /// from 172.16.0.0 to 172.31.255.255, which is exactly sixteen patterns of
  /// the form `172.<16..31>.*`.
  static List<String>? _ipv4BlockPatterns(List<int> octets, int prefix) {
    if (prefix == 32) return [octets.join('.')];
    if (prefix < 8 || prefix > 31) return null;

    final fixedOctets = prefix ~/ 8;
    final fixed = octets.take(fixedOctets).join('.');
    if (prefix % 8 == 0) return ['$fixed.*'];

    final count = 1 << (8 * (fixedOctets + 1) - prefix);
    if (count > _maxBypassExpansion) return null;
    final base = octets[fixedOctets] & ~(count - 1);
    final moreOctetsFollow = fixedOctets + 1 < octets.length;
    return [
      for (var value = base; value < base + count; value++)
        moreOctetsFollow ? '$fixed.$value.*' : '$fixed.$value',
    ];
  }

  static void _addUnique(List<String> entries, String entry) {
    if (!entries.contains(entry)) entries.add(entry);
  }

  static List<String> _uniquePreservingOrder(List<String> entries) {
    final unique = <String>[];
    for (final entry in entries) {
      _addUnique(unique, entry);
    }
    return unique;
  }

  // ==================== Windows registry helpers ====================

  static const String _internetSettingsKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';
  static const List<String> _windowsProxyValues = [
    'ProxyEnable',
    'ProxyServer',
    'ProxyOverride',
  ];

  Future<bool> _regAdd(String name, String type, String value) async {
    final result = await Process.run('reg', [
      'add',
      _internetSettingsKey,
      '/v',
      name,
      '/t',
      type,
      '/d',
      value,
      '/f',
    ]);
    if (result.exitCode != 0) {
      debugPrint('reg add $name failed: ${result.stderr}');
      return false;
    }
    return true;
  }

  Future<bool> _regDelete(String name) async {
    final result = await Process.run('reg', [
      'delete',
      _internetSettingsKey,
      '/v',
      name,
      '/f',
    ]);
    if (result.exitCode != 0) {
      debugPrint('reg delete $name failed: ${result.stderr}');
      return false;
    }
    return true;
  }

  /// Reads one value of the WinINET proxy settings, or `null` when it is unset.
  Future<Map<String, String>?> _regQuery(String name) async {
    final result = await Process.run('reg', [
      'query',
      _internetSettingsKey,
      '/v',
      name,
    ]);
    if (result.exitCode != 0) return null;

    final pattern = RegExp(
      '^\\s+${RegExp.escape(name)}\\s+(REG_\\w+)\\s+(.*)\$',
      multiLine: true,
    );
    final match = pattern.firstMatch(result.stdout.toString());
    if (match == null) return null;
    return {'type': match.group(1)!, 'value': match.group(2)!.trim()};
  }

  /// Whether WinINET currently has a **usable** proxy switched on.
  ///
  /// `ProxyEnable=1` with no `ProxyServer` is a half-written setting: Windows
  /// Settings shows the switch on and the address empty, and applications
  /// still reach the network directly. Reporting that as "off" keeps this
  /// app's own switch aligned with its promise — the registry state is what
  /// it is, but "on" must mean "traffic goes through a proxy".
  Future<bool> _readWindowsProxyEnabled() async {
    final enable = await _regQuery('ProxyEnable');
    if (enable?['value'] != '1') return false;
    final server = (await _regQuery('ProxyServer'))?['value'];
    return server != null && server.trim().isNotEmpty;
  }

  // ---- Telling WinINET's clients the settings moved ------------------------

  static const int _internetOptionRefresh = 37;
  static const int _internetOptionSettingsChanged = 39;

  /// Whether WinINET's proxy server points at [port] on whichever host.
  ///
  /// The value is either `host:port`, a bare host (default port), or one
  /// `scheme=host:port` entry per scheme separated by semicolons.
  Future<bool> _windowsProxyTargets(int port) async {
    final server = (await _regQuery('ProxyServer'))?['value'];
    if (server == null) return false;

    for (final entry in server.split(';')) {
      final endpoint = entry.contains('=')
          ? entry.split('=').last.trim()
          : entry.trim();
      if (endpoint.endsWith(':$port')) return true;
    }
    return false;
  }

  static bool _wininetUnavailable = false;
  static int Function(Pointer<Void>, int, Pointer<Void>, int)?
  _internetSetOption;

  /// `InternetSetOptionW(NULL, …)` is how a WinINET configuration change is
  /// announced, and writing the registry values is only half of applying it:
  /// every application that caches its proxy configuration — every browser —
  /// keeps dialling the old endpoint until this notification arrives. Without
  /// it, a proxy this app just enabled looks like it does nothing until the
  /// browser is restarted, which is the classic "the switch is on but the
  /// traffic is not" report.
  void _broadcastWinInetChange() {
    if (!Platform.isWindows) return;
    final setOption = _loadInternetSetOption();
    if (setOption == null) return;
    // Documented order: SETTINGS_CHANGED makes applications re-read, REFRESH
    // makes the proxy resolver drop its own cached answer.
    for (final option in const [
      _internetOptionSettingsChanged,
      _internetOptionRefresh,
    ]) {
      final applied = setOption(nullptr, option, nullptr, 0);
      if (applied == 0) {
        debugPrint('InternetSetOption($option) reported failure');
      }
    }
  }

  /// Binds `wininet.dll` once, and remembers a failure so it is not retried on
  /// every proxy change.
  static int Function(Pointer<Void>, int, Pointer<Void>, int)?
  _loadInternetSetOption() {
    if (_wininetUnavailable) return null;
    final cached = _internetSetOption;
    if (cached != null) return cached;

    try {
      final library = DynamicLibrary.open('wininet.dll');
      final setOption = library
          .lookupFunction<
            Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
            int Function(Pointer<Void>, int, Pointer<Void>, int)
          >('InternetSetOptionW');
      _internetSetOption = setOption;
      return setOption;
    } catch (error) {
      _wininetUnavailable = true;
      debugPrint(
        'wininet.dll could not be loaded; proxy changes will not be '
        'broadcast to running applications: $error',
      );
      return null;
    }
  }

  Future<File> _windowsProxySnapshotFile() async {
    final support = await getApplicationSupportDirectory();
    return File(
      '${support.path}${Platform.pathSeparator}windows-proxy-snapshot.json',
    );
  }

  /// Records the current WinINET proxy values before this app changes them.
  /// An existing snapshot is kept, so a second enable cannot overwrite the
  /// user's original settings with values this app wrote earlier.
  Future<void> _snapshotWindowsProxySettings() async {
    final file = await _windowsProxySnapshotFile();
    if (file.existsSync()) return;

    final snapshot = <String, Map<String, String>?>{};
    for (final name in _windowsProxyValues) {
      snapshot[name] = await _regQuery(name);
    }
    await file.writeAsString(jsonEncode(snapshot), flush: true);
  }

  /// Puts the snapshot back and drops it. Returns false when there was no
  /// snapshot to restore.
  Future<bool> _restoreWindowsProxySettings() async {
    final file = await _windowsProxySnapshotFile();
    if (!file.existsSync()) return false;

    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      debugPrint('Windows proxy snapshot is malformed; clearing it');
      await file.delete();
      return false;
    }

    var restored = true;
    for (final name in _windowsProxyValues) {
      final record = decoded[name];
      if (record is Map) {
        restored =
            await _regAdd(
              name,
              record['type']?.toString() ?? 'REG_SZ',
              record['value']?.toString() ?? '',
            ) &&
            restored;
      } else {
        restored = await _regDelete(name) && restored;
      }
    }
    if (restored) {
      await file.delete();
    } else {
      debugPrint('Windows proxy settings could not be fully restored');
    }
    return restored;
  }
}
