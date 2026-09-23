import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:arcadia_plus/src/rust/api.dart' as rust_api;
import 'package:arcadia_plus/src/utils/platform_utils.dart';

enum ProxyMode { global, rule, direct }

class PlatformProxyService {
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
      _currentProxyMode = mode;
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
            _tunModeEnabled = isRunning;
            _vpnFd = fd;
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
            _tunModeEnabled = args['isRunning'] as bool? ?? false;
            _vpnFd = (args['fd'] as num?)?.toInt() ?? -1;
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
        return await _enableMacOSSystemProxy(host, httpPort);
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
        _tunModeEnabled = status.enabled;
        if (status.enabled) {
          _currentProxyMode = mode;
        }
        if (status.error case final error?) {
          debugPrint('Failed to enable TUN mode: $error');
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
        _tunModeEnabled = status.enabled;
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
  Future<bool> _enableWindowsSystemProxy(
    String host,
    int port,
    List<String> bypass,
  ) async {
    final endpointHost = host.contains(':') && !host.startsWith('[')
        ? '[$host]'
        : host;
    final endpoint = '$endpointHost:$port';
    final override = <String>[...bypass, '<local>'].join(';');

    try {
      await _snapshotWindowsProxySettings();
      final enabled =
          await _regAdd('ProxyEnable', 'REG_DWORD', '1') &&
          await _regAdd('ProxyServer', 'REG_SZ', endpoint) &&
          await _regAdd('ProxyOverride', 'REG_SZ', override);
      _systemProxyEnabled = enabled;
      if (!enabled) {
        debugPrint('Windows system proxy could not be set completely');
      }
      return enabled;
    } catch (e) {
      debugPrint('Windows proxy error: $e');
      return false;
    }
  }

  Future<bool> _disableWindowsSystemProxy() async {
    try {
      final restored = await _restoreWindowsProxySettings();
      if (!restored) {
        // No usable snapshot: fall back to switching the proxy off rather
        // than leaving the machine pointed at a port nobody listens on.
        await _regAdd('ProxyEnable', 'REG_DWORD', '0');
      }
      _systemProxyEnabled = false;
      return restored;
    } catch (e) {
      debugPrint('Windows proxy disable error: $e');
      _systemProxyEnabled = false;
      return false;
    }
  }

  Future<bool> _enableWindowsTun(ProxyMode mode) async {
    try {
      await rust_api.ensureWintunDll();
      final status = await rust_api.enableTunModeWithMode(mode: mode.name);
      _tunModeEnabled = status.enabled;
      if (status.enabled) {
        _currentProxyMode = mode;
      } else if (status.error case final error?) {
        debugPrint('Windows TUN error: $error');
      }
      return _tunModeEnabled;
    } catch (e) {
      debugPrint('Windows TUN error: $e');
      return false;
    }
  }

  Future<bool> _disableWindowsTun() async {
    try {
      final status = await rust_api.disableTunMode();
      _tunModeEnabled = status.enabled;
      return !_tunModeEnabled;
    } catch (e) {
      debugPrint('Windows TUN disable error: $e');
      _tunModeEnabled = false;
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
        _currentProxyMode = mode;
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
      _tunModeEnabled = status.enabled;
      if (status.enabled) {
        _currentProxyMode = mode;
      } else if (status.error case final error?) {
        debugPrint('Windows TUN error: $error');
      }
      return _tunModeEnabled;
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
      _tunModeEnabled = false;
      _vpnFd = -1;

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

      _tunModeEnabled = true;
      _currentProxyMode = mode;
      debugPrint(
        '=== _enableAndroidVpn: VPN enabled successfully, fd=$_vpnFd, mode=$mode ===',
      );
      return true;
    } on PlatformException catch (e) {
      debugPrint(
        '_enableAndroidVpn: PlatformException: ${e.code} - ${e.message}',
      );
      _tunModeEnabled = false;
      _vpnFd = -1;
      return false;
    } catch (e, stackTrace) {
      debugPrint('_enableAndroidVpn: Unexpected error: $e');
      debugPrint('Stack trace: $stackTrace');
      _tunModeEnabled = false;
      _vpnFd = -1;
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

      _tunModeEnabled = false;
      _vpnFd = -1;

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
      _tunModeEnabled = false;
      _vpnFd = -1;
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

      _tunModeEnabled = false;
      _vpnFd = -1;

      final result = await _ohosChannel.invokeMethod('startVpn', {
        'mode': mode.name,
      });

      if (result is Map) {
        final success = result['success'] as bool? ?? false;
        final fd = (result['fd'] as num?)?.toInt() ?? -1;

        if (!success || fd < 0) {
          return false;
        }
        _vpnFd = fd;
      } else if (result != true) {
        return false;
      }

      try {
        rust_api.setAndroidVpnFd(fd: _vpnFd);
        rust_api.setAndroidProxyMode(mode: mode.name);
        final vpnStarted = await rust_api.startAndroidVpn();
        if (!vpnStarted) {
          return false;
        }
      } catch (e) {
        debugPrint('_enableOhosVpn: Failed to start Rust VPN: $e');
        return false;
      }

      _tunModeEnabled = true;
      _currentProxyMode = mode;
      return true;
    } on PlatformException catch (e) {
      debugPrint('_enableOhosVpn: PlatformException: ${e.message}');
      _tunModeEnabled = false;
      _vpnFd = -1;
      return false;
    }
  }

  Future<bool> _disableOhosVpn() async {
    try {
      await _ohosChannel.invokeMethod('stopVpn');
      _tunModeEnabled = false;
      _vpnFd = -1;
      try {
        await rust_api.stopAndroidVpn();
        rust_api.clearAndroidVpnFd();
      } catch (e) {
        debugPrint('Failed to cleanup Rust VPN state on OHOS: $e');
      }
      return true;
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
      if (result == true) {
        _currentProxyMode = mode;
        await rust_api.setAndroidProxyMode(mode: mode.name);
      }
      return result == true;
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
    _currentProxyMode = mode;
    return true;
  }

  Future<bool> setAndroidProxyMode(ProxyMode mode) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod('setProxyMode', {
        'mode': mode.name,
      });
      if (result == true) {
        _currentProxyMode = mode;
        await rust_api.setAndroidProxyMode(mode: mode.name);
      }
      return result == true;
    } catch (e) {
      debugPrint('Failed to set proxy mode: $e');
      return false;
    }
  }

  Future<bool> _enableMacOSSystemProxy(String host, int port) async {
    try {
      final services = await _macOSNetworkServices();
      if (services.isEmpty) {
        debugPrint('macOS proxy error: no network services to configure');
        return false;
      }
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
      }
      _systemProxyEnabled = applied;
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
      _systemProxyEnabled = false;
      return applied;
    } catch (e) {
      debugPrint('macOS proxy disable error: $e');
      return false;
    }
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
      _systemProxyEnabled = true;
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
      _systemProxyEnabled = false;
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
  Future<bool> checkSystemProxyStatus() async {
    try {
      if (Platform.isWindows) {
        final value = await _regQuery('ProxyEnable');
        _systemProxyEnabled = value?['value'] == '1';
        return _systemProxyEnabled;
      }
      if (Platform.isLinux) {
        final result = await Process.run('gsettings', [
          'get',
          'org.gnome.system.proxy',
          'mode',
        ]);
        _systemProxyEnabled =
            result.exitCode == 0 &&
            result.stdout.toString().trim().replaceAll("'", '') == 'manual';
        return _systemProxyEnabled;
      }
      return _systemProxyEnabled;
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
        _tunModeEnabled = isRunning;
        if (isRunning) {
          _vpnFd = await _channel.invokeMethod('getVpnFd') as int? ?? -1;
        }
        return _tunModeEnabled;
      }
      if (PlatformUtils.isOHOS) {
        final result = await _ohosChannel.invokeMethod('isVpnRunning');
        _tunModeEnabled = result == true;
        return _tunModeEnabled;
      }
      final status = await rust_api.getTunStatus();
      _tunModeEnabled = status.enabled;
      return _tunModeEnabled;
    } catch (e) {
      debugPrint('Failed to check TUN status: $e');
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
