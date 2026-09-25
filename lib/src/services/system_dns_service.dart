import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:arcadiaplus/src/services/dns_upstreams.dart';
import 'package:arcadiaplus/src/utils/platform_utils.dart';

/// Reads the DNS servers the platform itself is configured to use.
///
/// The engine has no `append-system-dns` key — corduit's `dns` section carries
/// nameservers, not the OS's — so the app-level switch of that name is honoured
/// here instead: the platform's own resolvers are read and appended to the
/// upstream list the config hands to the engine. A switch that changes nothing
/// would be worse than no switch at all.
///
/// Only what the platform actually exposes is read, and nothing is guessed:
///
/// * Linux and macOS: `nameserver` lines of `/etc/resolv.conf`.
/// * Windows: `NameServer` / `DhcpNameServer` values under
///   `HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces`.
/// * Android and iOS: nothing. The OS keeps its resolvers in the VPN stack,
///   where no supported API exposes them, so [isSupported] is false there and
///   the settings screen hides the switch rather than offering a no-op.
///
/// Every failure path returns an empty list and logs. This runs while a config
/// is being built, and no resolver lookup is worth failing a profile load over.
class SystemDnsService {
  SystemDnsService._();

  static final SystemDnsService instance = SystemDnsService._();

  /// How long a reading is reused. Long enough that starting or reloading a
  /// profile does not re-spawn `reg` each time, short enough that plugging into
  /// another network is picked up without restarting the app.
  static const Duration cacheLifetime = Duration(seconds: 30);

  /// Time a platform query may take before it is abandoned.
  static const Duration queryTimeout = Duration(seconds: 3);

  List<String>? _cached;
  DateTime? _cachedAt;

  /// Whether this platform exposes its resolvers at all.
  static bool get isSupported => PlatformUtils.isDesktop;

  /// The platform's resolvers, in the order the platform lists them.
  ///
  /// Loopback entries are dropped: on a systemd-resolved host the platform
  /// resolver is `127.0.0.53`, and on a machine where this app's own DNS
  /// listener is the configured resolver, appending it would point the engine
  /// at itself.
  Future<List<String>> read() async {
    if (!isSupported) return const [];

    final cached = _cached;
    final cachedAt = _cachedAt;
    if (cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < cacheLifetime) {
      return cached;
    }

    final servers = sanitise(await _readFromPlatform());
    _cached = servers;
    _cachedAt = DateTime.now();
    return servers;
  }

  /// Drops the cached reading, so the next [read] queries the platform again.
  void invalidate() {
    _cached = null;
    _cachedAt = null;
  }

  Future<List<String>> _readFromPlatform() async {
    try {
      if (Platform.isWindows) return await _readWindowsRegistry();
      if (Platform.isLinux || Platform.isMacOS) return await _readResolvConf();
    } catch (error) {
      debugPrint('Failed to read the system resolvers: $error');
    }
    return const [];
  }

  Future<List<String>> _readResolvConf() async {
    final file = File('/etc/resolv.conf');
    if (!await file.exists()) return const [];
    return parseResolvConf(await file.readAsString());
  }

  Future<List<String>> _readWindowsRegistry() async {
    final result = await Process.run('reg', [
      'query',
      _windowsInterfacesKey,
      '/s',
    ]).timeout(queryTimeout);
    if (result.exitCode != 0) {
      debugPrint('reg query exited with ${result.exitCode}: ${result.stderr}');
      return const [];
    }
    return parseWindowsRegistry('${result.stdout}');
  }

  static const String _windowsInterfacesKey =
      r'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces';

  /// `nameserver 1.1.1.1` lines of a resolv.conf-style file, in order.
  ///
  /// Comments (`#`, `;`) and every other directive are ignored; a `nameserver`
  /// line without an address is skipped rather than guessed at.
  static List<String> parseResolvConf(String contents) {
    final servers = <String>[];
    for (final rawLine in contents.split('\n')) {
      final line = rawLine.split('#').first.split(';').first.trim();
      if (line.isEmpty) continue;

      final fields = line.split(RegExp(r'\s+'));
      if (fields.length < 2 || fields.first.toLowerCase() != 'nameserver') {
        continue;
      }
      servers.add(fields[1]);
    }
    return servers;
  }

  /// `NameServer` / `DhcpNameServer` values of a `reg query <interfaces> /s`.
  ///
  /// Both value names are read because a DHCP-configured adapter stores its
  /// resolvers under `DhcpNameServer` and only keeps a static list under
  /// `NameServer`; taking one and ignoring the other loses the resolvers of
  /// whichever kind of adapter the machine happens to use. Values may hold
  /// several addresses separated by commas or spaces.
  static List<String> parseWindowsRegistry(String output) {
    final pattern = RegExp(
      r'^\s*(?:NameServer|DhcpNameServer)\s+REG_SZ\s+(.+?)\s*$',
      caseSensitive: false,
      multiLine: true,
    );

    final servers = <String>[];
    for (final match in pattern.allMatches(output)) {
      servers.addAll(
        match
            .group(1)!
            .split(RegExp(r'[,\s]+'))
            .where((entry) => entry.isNotEmpty),
      );
    }
    return servers;
  }

  /// Filters [candidates] down to addresses that are safe to hand the engine.
  ///
  /// Keeps address literals only — a hostname here would have to be resolved
  /// before it could resolve anything, which is the dependency this list exists
  /// to remove — drops loopback, deduplicates, and preserves order.
  static List<String> sanitise(Iterable<String> candidates) {
    final servers = <String>[];
    for (final candidate in candidates) {
      final address = candidate.trim();
      if (address.isEmpty || servers.contains(address)) continue;
      if (!isAddressLiteral(address)) continue;
      if (isLoopbackLiteral(address)) continue;
      servers.add(address);
    }
    return servers;
  }
}
