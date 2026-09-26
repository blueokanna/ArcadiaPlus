import 'dart:convert';

import 'package:yaml/yaml.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';

/// Parsed proxy information for UI display
class ParsedProxy {
  final String name;
  final String type;
  final String? server;
  final int? port;
  final Map<String, dynamic> options;

  ParsedProxy({
    required this.name,
    required this.type,
    this.server,
    this.port,
    this.options = const {},
  });

  String get displayType {
    switch (type.toLowerCase()) {
      case 'ss':
      case 'shadowsocks':
        return 'Shadowsocks';
      case 'vmess':
        return 'Vmess';
      case 'vless':
        return 'Vless';
      case 'trojan':
        return 'Trojan';
      case 'hysteria':
        return 'Hysteria';
      case 'hysteria2':
        return 'Hysteria2';
      case 'tuic':
        return 'TUIC';
      case 'wireguard':
        return 'WireGuard';
      case 'http':
        return 'HTTP';
      case 'socks5':
      case 'socks':
        return 'SOCKS5';
      default:
        return type;
    }
  }
}

/// Parsed proxy group for UI display
class ParsedProxyGroup {
  final String name;
  final String type;
  final List<String> proxies;
  final String? url;
  final int? interval;
  final String? icon;

  ParsedProxyGroup({
    required this.name,
    required this.type,
    required this.proxies,
    this.url,
    this.interval,
    this.icon,
  });

  String get displayType {
    switch (type.toLowerCase()) {
      case 'select':
        return '手动选择';
      case 'url-test':
        return '自动选择';
      case 'fallback':
        return '故障转移';
      case 'load-balance':
        return '负载均衡';
      case 'relay':
        return '链式代理';
      default:
        return type;
    }
  }
}

/// Parsed Clash config for UI display
class ParsedClashConfig {
  final List<ParsedProxy> proxies;
  final List<ParsedProxyGroup> proxyGroups;
  final Map<String, dynamic> general;
  final Map<String, dynamic> dns;
  final List<String> rules;

  ParsedClashConfig({
    required this.proxies,
    required this.proxyGroups,
    required this.general,
    required this.dns,
    required this.rules,
  });
}

/// Converts Clash YAML configuration to ArcadiaPlus JSON format
class ConfigConverter {
  /// Parse Clash YAML config for UI display
  static ParsedClashConfig parseClashConfig(String yamlContent) {
    try {
      final yamlMap = loadYaml(yamlContent);
      if (yamlMap == null) {
        throw Exception('Empty YAML content');
      }

      final config = _convertToMap(yamlMap);

      // Parse proxies
      final proxies = <ParsedProxy>[];
      final proxiesList = config['proxies'] as List? ?? [];
      for (final proxy in proxiesList) {
        if (proxy is Map) {
          final proxyMap = _convertToMap(proxy) as Map<String, dynamic>;
          final options = Map<String, dynamic>.from(proxyMap);
          options.remove('name');
          options.remove('type');
          options.remove('server');
          options.remove('port');

          proxies.add(
            ParsedProxy(
              name: proxyMap['name']?.toString() ?? 'Unknown',
              type: proxyMap['type']?.toString() ?? 'unknown',
              server: proxyMap['server']?.toString(),
              port: proxyMap['port'] is int
                  ? proxyMap['port']
                  : int.tryParse(proxyMap['port']?.toString() ?? ''),
              options: options,
            ),
          );
        }
      }

      // Parse proxy groups
      final proxyGroups = <ParsedProxyGroup>[];
      final groupsList = config['proxy-groups'] as List? ?? [];
      for (final group in groupsList) {
        if (group is Map) {
          final groupMap = _convertToMap(group) as Map<String, dynamic>;
          proxyGroups.add(
            ParsedProxyGroup(
              name: groupMap['name']?.toString() ?? 'Unknown',
              type: groupMap['type']?.toString() ?? 'select',
              proxies:
                  (groupMap['proxies'] as List?)
                      ?.map((e) => e.toString())
                      .toList() ??
                  [],
              url: groupMap['url']?.toString(),
              interval: groupMap['interval'] is int
                  ? groupMap['interval']
                  : null,
              icon: groupMap['icon']?.toString(),
            ),
          );
        }
      }

      // Parse rules
      final rules = <String>[];
      final rulesList = config['rules'] as List? ?? [];
      for (final rule in rulesList) {
        if (rule is String) {
          rules.add(rule);
        }
      }

      return ParsedClashConfig(
        proxies: proxies,
        proxyGroups: proxyGroups,
        general: {
          'port': config['port'],
          'socks-port': config['socks-port'],
          'mixed-port': config['mixed-port'],
          'allow-lan': config['allow-lan'],
          'mode': config['mode'],
          'log-level': config['log-level'],
        },
        dns: config['dns'] != null
            ? Map<String, dynamic>.from(_convertToMap(config['dns']) as Map)
            : <String, dynamic>{},
        rules: rules,
      );
    } catch (e) {
      throw Exception('Failed to parse config: $e');
    }
  }

  /// Convert Clash YAML config to ArcadiaPlus JSON config
  /// If generalSettings is provided, it will override the port settings from YAML
  ///
  /// [ruleProviderPaths] maps a `rule-providers` name onto the local file the
  /// `RuleProviderService` has already downloaded and normalised. Providers
  /// without a local copy are dropped together with the `RULE-SET` rules that
  /// reference them, which is how Clash behaves with an unloaded provider:
  /// the rule simply does not match and evaluation falls through.
  static String convertClashYamlToJson(
    String yamlContent, {
    GeneralSettings? generalSettings,
    DnsSettings? dnsSettings,
    String? recursiveDnsAddress,
    List<String> systemDnsServers = const [],
    Map<String, String>? ruleProviderPaths,
    void Function(String message)? onWarning,
  }) {
    try {
      final yamlMap = loadYaml(yamlContent);
      if (yamlMap == null) {
        throw Exception('Empty YAML content');
      }

      final config = _convertToMap(yamlMap);
      final arcadiaplusConfig = _convertClashToArcadiaPlus(
        config,
        generalSettings: generalSettings,
        dnsSettings: dnsSettings,
        recursiveDnsAddress: recursiveDnsAddress,
        systemDnsServers: systemDnsServers,
        ruleProviderPaths: ruleProviderPaths,
        onWarning: onWarning,
      );

      return jsonEncode(arcadiaplusConfig);
    } catch (e) {
      throw Exception('Failed to convert config: $e');
    }
  }

  /// Convert YamlMap to regular Map recursively
  static dynamic _convertToMap(dynamic value) {
    if (value is YamlMap) {
      return Map<String, dynamic>.fromEntries(
        value.entries.map(
          (e) => MapEntry(e.key.toString(), _convertToMap(e.value)),
        ),
      );
    } else if (value is YamlList) {
      return value.map((e) => _convertToMap(e)).toList();
    } else if (value is Map) {
      // Handle regular Map (e.g., empty map {})
      return Map<String, dynamic>.fromEntries(
        value.entries.map(
          (e) => MapEntry(e.key.toString(), _convertToMap(e.value)),
        ),
      );
    }
    return value;
  }

  /// Convert Clash config format to ArcadiaPlus config format
  static Map<String, dynamic> _convertClashToArcadiaPlus(
    Map<String, dynamic> clash, {
    GeneralSettings? generalSettings,
    DnsSettings? dnsSettings,
    String? recursiveDnsAddress,
    List<String> systemDnsServers = const [],
    Map<String, String>? ruleProviderPaths,
    void Function(String message)? onWarning,
  }) {
    final (outbounds, availableOutbounds) = _extractOutbounds(
      clash,
      onWarning: onWarning,
    );

    final (ruleProviders, availableRuleSets) = _extractRuleProviders(
      clash,
      localPaths: ruleProviderPaths,
      onWarning: onWarning,
    );

    return {
      'general': _extractGeneralConfig(
        clash,
        generalSettings: generalSettings,
        onWarning: onWarning,
      ),
      'dns': _extractDnsConfig(
        clash,
        dnsSettings: dnsSettings,
        recursiveDnsAddress: recursiveDnsAddress,
        systemDnsServers: systemDnsServers,
        onWarning: onWarning,
      ),
      'inbounds': _extractInbounds(clash, generalSettings: generalSettings),
      'outbounds': outbounds,
      'rules': _extractRules(
        clash,
        availableOutbounds: availableOutbounds,
        availableRuleSets: availableRuleSets,
        onWarning: onWarning,
      ),
      'rule_providers': ruleProviders,
    };
  }

  /// Builds the engine's `rule_providers` section from the profile and the
  /// local copies the rule provider service produced.
  ///
  /// The engine is always handed `type: file` providers: it loads them from
  /// disk in one synchronous step, so an unreachable rule source can never
  /// fail or stall engine start-up. Returns the provider list together with
  /// the set of names that are actually backed by a file, so `RULE-SET` rules
  /// referencing a missing provider can be dropped instead of failing
  /// validation inside the engine.
  static (List<Map<String, dynamic>>, Set<String>) _extractRuleProviders(
    Map<String, dynamic> clash, {
    Map<String, String>? localPaths,
    void Function(String message)? onWarning,
  }) {
    final source = clash['rule-providers'];
    if (source is! Map) {
      return (const <Map<String, dynamic>>[], const <String>{});
    }

    final providers = <Map<String, dynamic>>[];
    final ready = <String>{};

    for (final entry in source.entries) {
      final name = entry.key.toString();
      if (entry.value is! Map) {
        throw FormatException('Rule provider "$name" is not a mapping');
      }
      final config = Map<String, dynamic>.from(entry.value as Map);
      final type = (config['type'] ?? 'http').toString().toLowerCase();
      final behavior = (config['behavior'] ?? 'classical')
          .toString()
          .toLowerCase();
      if (type != 'http' && type != 'file') {
        throw FormatException('Unsupported rule provider type: $type');
      }
      if (!const {'domain', 'ipcidr', 'classical'}.contains(behavior)) {
        throw FormatException('Unsupported rule provider behavior: $behavior');
      }
      if (type == 'http' && (config['url']?.toString().isEmpty ?? true)) {
        throw FormatException('Rule provider "$name" needs a url');
      }
      if (type == 'file' && (config['path']?.toString().isEmpty ?? true)) {
        throw FormatException('Rule provider "$name" needs a path');
      }

      final localPath = localPaths?[name];
      if (localPath == null) {
        onWarning?.call(
          'Rule provider "$name" has no local copy; its rules are inactive '
          'until the rule set is downloaded.',
        );
        continue;
      }

      ready.add(name);
      providers.add({
        'name': name,
        'type': 'file',
        'behavior': behavior,
        'path': localPath,
        // The engine re-reads a local provider on this interval. Refreshed
        // rule sets land on a new content-addressed path, so a real update is
        // picked up on the next reload rather than this timer; the floor
        // keeps a profile that declares a tiny interval from making the
        // background updater spin.
        'interval': _providerInterval(config['interval']),
      });
    }

    return (providers, ready);
  }

  static int _providerInterval(Object? declared) {
    const floor = 600;
    const fallback = 86400;
    final value = declared is int
        ? declared
        : int.tryParse(declared?.toString() ?? '');
    if (value == null) return fallback;
    return value < floor ? floor : value;
  }

  static Map<String, dynamic> _extractGeneralConfig(
    Map<String, dynamic> clash, {
    GeneralSettings? generalSettings,
    void Function(String message)? onWarning,
  }) {
    // Use generalSettings if provided, otherwise fall back to YAML values.
    // The HTTP port is not read here: it reaches the engine as an inbound, built
    // by `_extractInbounds` from the same setting.
    final socksPort = generalSettings?.socksPort ?? clash['socks-port'];
    final mixedPort = generalSettings?.mixedPort ?? clash['mixed-port'];
    final allowLan = generalSettings?.allowLan ?? clash['allow-lan'] ?? false;
    final ipv6 = generalSettings?.ipv6 ?? clash['ipv6'] ?? false;
    final tcpConcurrent =
        generalSettings?.tcpConcurrent ?? clash['tcp-concurrent'] ?? false;
    final authentication = clash['authentication'] is List
        ? (clash['authentication'] as List).map((auth) {
            final parts = auth.toString().split(':');
            return {
              'username': parts.isNotEmpty ? parts[0] : '',
              'password': parts.length > 1 ? parts[1] : '',
            };
          }).toList()
        : null;
    var bindAddress =
        generalSettings?.bindAddress ?? clash['bind-address'] ?? '*';

    // Convert '*' or invalid addresses to proper IP format
    if (bindAddress == '*') {
      if (allowLan) {
        bindAddress = ipv6 ? '::' : '0.0.0.0';
      } else {
        bindAddress = ipv6 ? '::1' : '127.0.0.1';
      }
    }

    if (allowLan && bindAddress != '127.0.0.1' && bindAddress != '::1') {
      onWarning?.call(
        authentication == null || authentication.isEmpty
            ? 'allow-lan is on and no inbound authentication is configured: '
                  'every host that can reach this machine may use the proxy.'
            : 'allow-lan is on: the proxy listens on $bindAddress and is '
                  'reachable from the local network.',
      );
    }

    final mode = _normaliseMode(
      generalSettings?.mode ?? clash['mode'],
      onWarning: onWarning,
    );
    final logLevel = _normaliseLogLevel(
      generalSettings?.logLevel ?? clash['log-level'],
      onWarning: onWarning,
    );

    // `port`, `redir-port` and `tproxy-port` are deliberately not sent. The
    // HTTP, SOCKS and mixed ports reach the engine as real inbounds instead, and
    // the transparent-proxy ports have no implementation to reach at all — a
    // field read by nothing is how a settings screen ends up lying.
    for (final legacy in ['redir-port', 'tproxy-port']) {
      if (clash[legacy] != null) {
        onWarning?.call(
          '$legacy is not supported: this engine has no transparent-proxy '
          'inbound, so the setting has no effect.',
        );
      }
    }

    return {
      'socks_port': socksPort,
      'mixed_port': mixedPort,
      'authentication': authentication,
      'allow_lan': allowLan,
      'bind_address': bindAddress,
      'mode': mode,
      'log_level': logLevel,
      'ipv6': ipv6,
      'tcp_concurrent': tcpConcurrent,
      'external_controller':
          generalSettings?.externalController ?? clash['external-controller'],
      'external_ui': generalSettings?.externalUi ?? clash['external-ui'],
      'secret': generalSettings?.secret ?? clash['secret'],
    };
  }

  /// Builds the engine's `dns` section.
  ///
  /// Two sources exist and one has to win: the profile's own `dns` block, or
  /// the app's DNS settings once the user turns on "override DNS". The switch
  /// is what makes the choice explicit instead of silently preferring one.
  ///
  /// [systemDnsServers] is the platform's own resolver list, read by
  /// `SystemDnsService` when "append system DNS" is on. The engine has no such
  /// key, so the setting is expressed by appending: a machine that reaches its
  /// local resolvers but not a public DoH endpoint keeps working.
  static Map<String, dynamic> _extractDnsConfig(
    Map<String, dynamic> clash, {
    DnsSettings? dnsSettings,
    String? recursiveDnsAddress,
    List<String> systemDnsServers = const [],
    void Function(String message)? onWarning,
  }) {
    final override = dnsSettings != null && dnsSettings.overrideDns;
    final dns = override
        ? const <String, dynamic>{}
        : (clash['dns'] as Map<String, dynamic>? ?? {});

    final configured = override
        ? dnsSettings.nameservers
        : _toStringList(dns['nameserver']);
    final effectiveConfigured = configured.isEmpty
        ? const ['8.8.8.8', '1.1.1.1']
        : configured;

    final withSystemDns = <String>[...effectiveConfigured];
    for (final server in systemDnsServers) {
      if (!withSystemDns.contains(server)) withSystemDns.add(server);
    }

    // A running RecurseX front-end stays authoritative: put it first and
    // every forwarded query becomes a recursive one, with the configured
    // upstreams kept behind it as fallbacks.
    final nameservers = recursiveDnsAddress == null
        ? withSystemDns
        : [recursiveDnsAddress, ...withSystemDns];

    final fallback = override
        ? dnsSettings.fallback
        : _toStringList(dns['fallback']);

    // `nameserver-policy` always comes from the profile: it is how a
    // subscription makes its own node domains resolvable (typically a
    // private TCP resolver). Overriding the general DNS servers must not
    // break the node bootstrap.
    final policy = <String, List<String>>{};
    final rawPolicy =
        clash['dns']?['nameserver-policy'] as Map<String, dynamic>?;
    rawPolicy?.forEach((key, value) {
      final servers = _toStringList(value);
      if (servers.isNotEmpty) {
        policy[key] = servers;
      }
    });

    // `default-nameserver` bootstraps the hostname of an upstream resolver
    // (`tls://doh.pub` needs *a* resolver before it can answer anything) and
    // `fallback-filter` decides when an answer is suspect enough to re-resolve
    // through `fallback`. Both are profile knowledge the app's own settings
    // cannot express, so they pass through unchanged — like the policy above,
    // an override of the general servers must not silently disarm them.
    final defaultNameserver = _toStringList(dns['default-nameserver']);
    final fallbackFilter = _extractFallbackFilter(dns['fallback-filter']);

    // Pass-through keys the app's own DNS settings cannot express yet, so they
    // come from the profile. With "override DNS" on, `dns` is empty and every
    // key below is omitted — leaving the engine's own defaults in place rather
    // than handing it a value nobody chose.
    final fakeIpRange = dns['fake-ip-range'];
    final fakeIpFilter = _toStringList(dns['fake-ip-filter']);
    final fakeIpTtl = _toPositiveInt(dns['fake-ip-ttl']);
    final cacheSize = _toPositiveInt(dns['cache-size']);
    // `use-hosts: false` in the profile means the hosts table must not be
    // consulted; shipping it anyway would be data the profile asked to
    // ignore, so it is not shipped at all.
    final useHosts = dns['use-hosts'];
    final hosts = useHosts == false
        ? const <String, String>{}
        : _extractHosts(dns['hosts']);

    return {
      'enable': override ? dnsSettings.enable : (dns['enable'] ?? true),
      'listen': override
          ? dnsSettings.listen
          : (dns['listen'] ?? '127.0.0.1:53'),
      'nameservers': nameservers,
      'fallback': fallback,
      if (defaultNameserver.isNotEmpty) 'default_nameserver': defaultNameserver,
      'fallback_filter': ?fallbackFilter,
      // mihomo's default is `redir-host`, not `fake-ip`. A profile that does not
      // name a mode gets real answers, which is what it would get under mihomo.
      'enhanced_mode': _normaliseDnsMode(
        override ? dnsSettings.dnsMode : dns['enhanced-mode'],
        onWarning: onWarning,
      ),
      'nameserver_policy': policy,
      if (fakeIpRange is String && fakeIpRange.trim().isNotEmpty)
        'fake_ip_range': fakeIpRange.trim(),
      if (fakeIpFilter.isNotEmpty) 'fake_ip_filter': fakeIpFilter,
      'fake_ip_ttl': ?fakeIpTtl,
      'cache_size': ?cacheSize,
      if (useHosts is bool) 'use_hosts': useHosts,
      if (hosts.isNotEmpty) 'hosts': hosts,
    };
  }

  /// The engine's spelling of a routing mode.
  ///
  /// Profiles are not consistent about case (`mode: Rule` is common in
  /// subscriptions), and the engine's vocabulary is exact — a value it cannot
  /// read fails the *whole* config, so the conversion has to land on one of
  /// the three words it knows. An unknown value is reported and the profile
  /// keeps mihomo's default instead of being sent something that would be
  /// rejected outright.
  static String _normaliseMode(
    Object? raw, {
    void Function(String message)? onWarning,
  }) {
    final value = raw?.toString().trim().toLowerCase() ?? '';
    switch (value) {
      case '':
      case 'rule':
        return 'rule';
      case 'global':
        return 'global';
      case 'direct':
        return 'direct';
      // mihomo's scripting mode has no equivalent here; a profile that asks
      // for it gets rule matching, and the difference is stated rather than
      // silently approximated.
      case 'script':
        onWarning?.call(
          'mode: script has no equivalent in this engine; rule matching is '
          'used instead.',
        );
        return 'rule';
      default:
        onWarning?.call(
          'mode: "$raw" is not a mode this engine knows; rule matching is used '
          'instead.',
        );
        return 'rule';
    }
  }

  /// The engine's spelling of a log level.
  ///
  /// Clash writes `warning`, hand-edited configs write `warn`, and either may
  /// arrive capitalised; the engine accepts `warning` and `warn`, so the value
  /// is lowercased and an unknown level falls back to `info` with a reason.
  static String _normaliseLogLevel(
    Object? raw, {
    void Function(String message)? onWarning,
  }) {
    final value = raw?.toString().trim().toLowerCase() ?? '';
    switch (value) {
      case '':
      case 'info':
      case 'debug':
      case 'error':
      case 'silent':
        return value.isEmpty ? 'info' : value;
      case 'warning':
      case 'warn':
        return 'warning';
      default:
        onWarning?.call(
          'log-level: "$raw" is not a level this engine knows; info is used '
          'instead.',
        );
        return 'info';
    }
  }

  /// The engine's spelling of a DNS mode.
  ///
  /// Three vocabularies name two behaviours: mihomo writes `redir-host` (and
  /// accepts `normal` for the same thing), this app's own settings offer both
  /// spellings, and the engine knows `normal` and `fake-ip`. Everything that
  /// means "answer with real addresses" becomes `normal`, everything that
  /// means "answer with addresses from the fake pool" becomes `fake-ip`, and a
  /// value that means neither is reported and left to the engine's default —
  /// an unreadable value here fails the whole config, which is how a working
  /// profile would otherwise stop starting.
  static String _normaliseDnsMode(
    Object? raw, {
    void Function(String message)? onWarning,
  }) {
    final value = raw?.toString().trim().toLowerCase() ?? '';
    switch (value) {
      case '':
      case 'normal':
      case 'redir-host':
      case 'redir_host':
      case 'redir':
        return 'normal';
      case 'fake-ip':
      case 'fakeip':
      case 'fake_ip':
        return 'fake-ip';
      default:
        onWarning?.call(
          'dns.enhanced-mode: "$raw" is not a mode this engine knows; real '
          'addresses (normal) are used instead.',
        );
        return 'normal';
    }
  }

  /// mihomo's `fallback-filter`, in the engine's spelling.
  ///
  /// `null` when the profile declares none: the engine then keeps its own
  /// default, which mirrors mihomo's (`geoip: true` / `geoip-code: CN`), rather
  /// than being handed a half-filled object this layer invented.
  static Map<String, dynamic>? _extractFallbackFilter(Object? raw) {
    if (raw is! Map) return null;
    final filter = <String, dynamic>{};
    final geoip = raw['geoip'];
    if (geoip is bool) filter['geoip'] = geoip;
    final geoipCode = raw['geoip-code'];
    if (geoipCode != null && geoipCode.toString().trim().isNotEmpty) {
      filter['geoip_code'] = geoipCode.toString().trim();
    }
    final ipcidr = _toStringList(raw['ipcidr']);
    if (ipcidr.isNotEmpty) filter['ipcidr'] = ipcidr;
    final domain = _toStringList(raw['domain']);
    if (domain.isNotEmpty) filter['domain'] = domain;
    return filter.isEmpty ? null : filter;
  }

  /// A positive integer, or null when the value is absent or nonsense.
  ///
  /// `cache-size: 0` would be a cache that never stores anything, which is a
  /// mistake rather than a setting, so it is treated as absent.
  static int? _toPositiveInt(Object? value) {
    final parsed = value is int ? value : int.tryParse('${value ?? ''}');
    if (parsed == null || parsed < 1) {
      return null;
    }
    return parsed;
  }

  /// The profile's `hosts` block, one string per name.
  ///
  /// Clash accepts a bare string or a list as the value, and a name-to-name
  /// alias. Every shape is forwarded as written: the engine keeps the entries
  /// it can use and reports the ones it cannot, which is better than this layer
  /// deciding for it and losing an entry silently.
  static Map<String, String> _extractHosts(Object? value) {
    if (value is! Map) {
      return const {};
    }
    final hosts = <String, String>{};
    value.forEach((key, entry) {
      if (key is! String || key.trim().isEmpty) {
        return;
      }
      final candidates = _toStringList(entry);
      if (candidates.isEmpty) {
        return;
      }
      hosts[key.trim()] = candidates.first;
    });
    return hosts;
  }

  /// Clash accepts a single server as a bare string wherever a list is also
  /// valid (`nameserver: 223.5.5.5`, `nameserver-policy: {a.com: 1.1.1.1}`).
  /// Normalizing both shapes here keeps scalar entries from being dropped.
  static List<String> _toStringList(Object? value) {
    if (value is String) {
      return value.isEmpty ? const [] : [value];
    }
    if (value is List) {
      return value
          .map((entry) => entry.toString())
          .where((entry) => entry.isNotEmpty)
          .toList();
    }
    return const [];
  }

  static List<Map<String, dynamic>> _extractInbounds(
    Map<String, dynamic> clash, {
    GeneralSettings? generalSettings,
  }) {
    final inbounds = <Map<String, dynamic>>[];

    // Use generalSettings if provided, otherwise fall back to YAML values
    final httpPort = generalSettings?.httpPort ?? clash['port'];
    final socksPort = generalSettings?.socksPort ?? clash['socks-port'];
    final mixedPort = generalSettings?.mixedPort ?? clash['mixed-port'];
    final allowLan = generalSettings?.allowLan ?? clash['allow-lan'] ?? false;
    final ipv6 = generalSettings?.ipv6 ?? clash['ipv6'] ?? false;
    var bindAddress =
        generalSettings?.bindAddress ?? clash['bind-address'] ?? '127.0.0.1';

    // Convert '*' or invalid addresses to proper IP format
    if (bindAddress == '*') {
      if (allowLan) {
        bindAddress = ipv6 ? '::' : '0.0.0.0';
      } else {
        bindAddress = ipv6 ? '::1' : '127.0.0.1';
      }
    }

    // HTTP inbound
    if (httpPort != null) {
      inbounds.add({
        'inbound_type': 'http',
        'tag': 'http-in',
        'listen': bindAddress,
        'port': httpPort,
        'options': '{}',
      });
    }

    // SOCKS inbound
    if (socksPort != null) {
      inbounds.add({
        'inbound_type': 'socks5',
        'tag': 'socks-in',
        'listen': bindAddress,
        'port': socksPort,
        'options': '{}',
      });
    }

    // Mixed inbound
    if (mixedPort != null) {
      inbounds.add({
        'inbound_type': 'mixed',
        'tag': 'mixed-in',
        'listen': bindAddress,
        'port': mixedPort,
        'options': '{}',
      });
    }

    // If no inbounds defined, add default mixed port
    if (inbounds.isEmpty) {
      inbounds.add({
        'inbound_type': 'mixed',
        'tag': 'mixed-in',
        'listen': '127.0.0.1',
        'port': 7897,
        'options': '{}',
      });
    }

    return inbounds;
  }

  /// Converts `proxies` and `proxy-groups` into corduit outbounds.
  ///
  /// Returns the outbounds plus every tag the finished config declares.
  /// A proxy whose protocol corduit cannot build is dropped, and because
  /// corduit's validator rejects dangling references, group members and
  /// rule targets are filtered against that tag set.
  static (List<Map<String, dynamic>>, Set<String>) _extractOutbounds(
    Map<String, dynamic> clash, {
    void Function(String message)? onWarning,
  }) {
    final outbounds = <Map<String, dynamic>>[];
    final dropped = <String>{};
    final proxies = clash['proxies'] as List? ?? [];
    final proxyGroups = clash['proxy-groups'] as List? ?? [];

    // Add DIRECT and REJECT first
    outbounds.add({
      'outbound_type': 'direct',
      'tag': 'DIRECT',
      'server': null,
      'port': null,
      'options': '{}',
    });

    outbounds.add({
      'outbound_type': 'reject',
      'tag': 'REJECT',
      'server': null,
      'port': null,
      'options': '{}',
    });

    // Convert proxies
    for (final proxy in proxies) {
      if (proxy is Map) {
        final proxyMap = _convertToMap(proxy) as Map<String, dynamic>;
        final proxyType =
            proxyMap['type']?.toString().toLowerCase() ?? 'unknown';
        final name = proxyMap['name']?.toString() ?? 'proxy';
        final mappedType = _mapProxyType(proxyType);

        if (mappedType == null) {
          dropped.add(name);
          onWarning?.call(
            'Proxy "$name" is a "$proxyType" node, which corduit cannot build. '
            'The node was dropped; references to it fall back to DIRECT.',
          );
          continue;
        }

        // Remove common fields for options
        final options = Map<String, dynamic>.from(proxyMap);
        options.remove('name');
        options.remove('type');
        options.remove('server');
        options.remove('port');

        outbounds.add({
          'outbound_type': mappedType,
          'tag': name,
          'server': proxyMap['server']?.toString(),
          'port': proxyMap['port'] is int
              ? proxyMap['port']
              : int.tryParse(proxyMap['port']?.toString() ?? ''),
          // corduit's FFI contract takes the protocol options as a JSON
          // string and decodes them into the engine's option map, keeping
          // the original Clash names (cipher, uuid, alterId, ws-opts, ...).
          'options': jsonEncode(options),
        });
      }
    }

    // Everything the finished config will declare, groups included: a group
    // may legitimately point at another group.
    final declared = <String>{'DIRECT', 'REJECT'};
    for (final outbound in outbounds) {
      declared.add(outbound['tag'] as String);
    }
    for (final group in proxyGroups) {
      if (group is Map) {
        final groupName = (_convertToMap(group) as Map<String, dynamic>)['name']
            ?.toString();
        if (groupName != null && groupName.isNotEmpty) {
          declared.add(groupName);
        }
      }
    }

    // Convert proxy groups to selector outbounds
    for (final group in proxyGroups) {
      if (group is Map) {
        final groupMap = _convertToMap(group) as Map<String, dynamic>;
        final groupType =
            groupMap['type']?.toString().toLowerCase() ?? 'select';
        final name = groupMap['name']?.toString() ?? 'group';
        final rawMembers =
            (groupMap['proxies'] as List?)?.map((e) => e.toString()).toList() ??
            [];

        final members = <String>[];
        for (final member in rawMembers) {
          if (declared.contains(member)) {
            members.add(member);
          } else {
            onWarning?.call(
              'Proxy group "$name" references "$member", which the config does '
              'not declare as a usable outbound; the member was dropped.',
            );
          }
        }

        // Map proxy group type to outbound type
        String outboundType;
        switch (groupType) {
          case 'select':
            outboundType = 'selector';
            break;
          case 'url-test':
            outboundType = 'urltest';
            break;
          case 'fallback':
            outboundType = 'fallback';
            break;
          case 'load-balance':
            outboundType = 'loadbalance';
            break;
          case 'relay':
            outboundType = 'relay';
            break;
          default:
            outboundType = 'selector';
        }

        // Build options map for group
        final optionsMap = <String, dynamic>{
          'outbounds': members.isEmpty ? const ['DIRECT'] : members,
        };
        if (groupMap['url'] != null) {
          optionsMap['url'] = groupMap['url'];
        }
        if (groupMap['interval'] != null) {
          optionsMap['interval'] = groupMap['interval'];
        }

        outbounds.add({
          'outbound_type': outboundType,
          'tag': name,
          'server': null,
          'port': null,
          'options': jsonEncode(optionsMap),
        });
      }
    }

    return (outbounds, declared);
  }

  /// Every Clash proxy type the engine can build, and the corduit outbound
  /// type it becomes.
  ///
  /// This map is the single source of truth for the mapping — the converter
  /// dispatches through it and [supportedProtocols] is derived from it, so a
  /// protocol cannot be advertised on one side and dropped on the other.
  ///
  /// Types corduit has no way to build (shadowsocksr, hysteria v1 and
  /// shadowquic today) are simply absent, which is what makes
  /// [_mapProxyType] return `null` for them. Order is the order protocols are
  /// listed in.
  static const Map<String, String> proxyTypeMapping = {
    'ss': 'shadowsocks',
    'shadowsocks': 'shadowsocks',
    'vmess': 'vmess',
    'vless': 'vless',
    'trojan': 'trojan',
    'hysteria2': 'hysteria2',
    'hy2': 'hysteria2',
    'tuic': 'tuic',
    'wireguard': 'wireguard',
    'http': 'http',
    'socks5': 'socks5',
    'socks': 'socks5',
  };

  /// How each outbound type is written for people.
  static const Map<String, String> _outboundDisplayNames = {
    'shadowsocks': 'Shadowsocks',
    'vmess': 'VMess',
    'vless': 'VLESS',
    'trojan': 'Trojan',
    'hysteria2': 'Hysteria2',
    'tuic': 'TUIC',
    'wireguard': 'WireGuard',
    'http': 'HTTP / HTTPS',
    'socks5': 'SOCKS5',
  };

  /// The protocols the engine can actually build, named as users know them.
  static List<String> get supportedProtocols => [
    for (final outbound in proxyTypeMapping.values.toSet())
      ?_outboundDisplayNames[outbound],
  ];

  /// Maps a Clash proxy type onto a corduit outbound type.
  ///
  /// `null` means corduit has no way to build this protocol (shadowsocksr,
  /// hysteria v1 and shadowquic today); such a node is dropped from the
  /// outbound list and every reference to it is rewritten.
  static String? _mapProxyType(String clashType) => proxyTypeMapping[clashType];

  static List<Map<String, dynamic>> _extractRules(
    Map<String, dynamic> clash, {
    required Set<String> availableOutbounds,
    required Set<String> availableRuleSets,
    void Function(String message)? onWarning,
  }) {
    final rules = <Map<String, dynamic>>[];
    final clashRules = clash['rules'] as List? ?? [];

    // corduit validates cross references, so a target that does not exist
    // has to become DIRECT here or the whole config is rejected.
    String resolveTarget(String target, String source) {
      if (availableOutbounds.contains(target)) {
        return target;
      }
      onWarning?.call(
        'Rule "$source" targets "$target", which the config does not '
        'declare; the rule falls back to DIRECT.',
      );
      return 'DIRECT';
    }

    for (final rule in clashRules) {
      if (rule is String) {
        final parts = _splitRuleFields(rule);
        if (parts.length >= 2) {
          final ruleType = parts[0].trim();
          final payload = parts.length >= 3 ? parts[1].trim() : '';
          final outbound = parts.length >= 3
              ? parts[2].trim()
              : parts[1].trim();
          final mappedType = _mapRuleType(ruleType);

          if (mappedType == null) {
            onWarning?.call(
              'Rule "$rule" uses "$ruleType", which corduit has no rule type '
              'for; the rule was skipped.',
            );
            continue;
          }

          // A `GEOSITE` entry names a category in the v2ray geosite database,
          // a data set this engine does not ship. As a rule type it reads the
          // category as a rule-provider name, so the entry is usable when the
          // profile itself defines a provider under that name — and must be
          // skipped otherwise: matching it against nothing would route the
          // traffic the rule was written to protect.
          if (mappedType == 'geosite' && !availableRuleSets.contains(payload)) {
            onWarning?.call(
              'Rule "$rule" references the geosite category "$payload", which '
              'is not available on this engine; the rule was skipped.',
            );
            continue;
          }

          // The engine rejects a RULE-SET naming an unconfigured provider, and
          // a provider without a local copy was dropped above. Skipping the
          // rule keeps the rest of the profile usable and matches Clash's
          // behaviour for a provider that never loaded.
          if (mappedType == 'rule_set' &&
              !availableRuleSets.contains(payload)) {
            onWarning?.call(
              'Rule "$rule" references the rule set "$payload", which is not '
              'available; the rule was skipped.',
            );
            continue;
          }

          // A logical rule matches on the shape of the traffic rather than on
          // one field, and its condition is a parenthesised list of sub-rules
          // rather than a single payload. The engine models exactly that with
          // nested child rules, so the list is converted instead of dropped.
          if (mappedType == 'and' ||
              mappedType == 'or' ||
              mappedType == 'not') {
            final children = _parseLogicalRule(
              payload,
              availableRuleSets: availableRuleSets,
            );
            if (children == null) {
              onWarning?.call(
                'Rule "$rule" has a condition this build cannot read; the '
                'rule was skipped.',
              );
              continue;
            }
            if (mappedType == 'not' && children.length != 1) {
              onWarning?.call(
                'Rule "$rule" negates ${children.length} conditions; NOT '
                'takes exactly one, so the rule was skipped.',
              );
              continue;
            }
            final target = resolveTarget(outbound, rule);
            rules.add({
              'rule_type': mappedType,
              'payload': '',
              'outbound': target,
              'process_name': null,
              'rules': _attachOutbound(children, target),
            });
            continue;
          }

          rules.add({
            'rule_type': mappedType,
            'payload': payload,
            'outbound': resolveTarget(outbound, rule),
            'process_name': null,
            // `no-resolve` travels with the rule: an IP rule carrying it may
            // only see the address the client supplied, never one the router
            // resolved — which is also what lets the router skip the lookup
            // entirely for a connection such a rule decides.
            if (parts
                .skip(3)
                .any((flag) => flag.trim().toLowerCase() == 'no-resolve'))
              'no_resolve': true,
          });
        }
      }
    }

    // Add final MATCH rule if not present
    if (rules.isEmpty || rules.last['rule_type'] != 'match') {
      rules.add({
        'rule_type': 'match',
        'payload': '',
        'outbound': resolveTarget(_defaultRuleOutbound(clash), 'MATCH'),
        'process_name': null,
      });
    }

    return rules;
  }

  static String _defaultRuleOutbound(Map<String, dynamic> clash) {
    final proxyGroups = clash['proxy-groups'] as List? ?? const [];
    for (final group in proxyGroups) {
      if (group is Map && group['name'] != null) {
        final name = group['name'].toString().trim();
        if (name.isNotEmpty && name != 'DIRECT' && name != 'REJECT') {
          return name;
        }
      }
    }

    final proxies = clash['proxies'] as List? ?? const [];
    for (final proxy in proxies) {
      if (proxy is Map && proxy['name'] != null) {
        final name = proxy['name'].toString().trim();
        if (name.isNotEmpty && name != 'DIRECT' && name != 'REJECT') {
          return name;
        }
      }
    }

    return 'DIRECT';
  }

  /// Splits one rule line on the commas that separate its fields.
  ///
  /// A logical rule carries a bracketed condition that has commas of its own
  /// (`AND,((DOMAIN-SUFFIX,a.com),(NETWORK,tcp)),PROXY`), so the split has to
  /// respect the brackets or the condition would be torn apart.
  static List<String> _splitRuleFields(String rule) {
    final fields = <String>[];
    final current = StringBuffer();
    var depth = 0;
    for (var i = 0; i < rule.length; i++) {
      final char = rule[i];
      if (char == '(') depth++;
      if (char == ')') depth = depth > 0 ? depth - 1 : 0;
      if (char == ',' && depth == 0) {
        fields.add(current.toString());
        current.clear();
        continue;
      }
      current.write(char);
    }
    fields.add(current.toString());
    return fields;
  }

  /// Returns the text inside one outer pair of parentheses, or `null` when the
  /// text is not a single balanced bracket.
  static String? _stripOuterParens(String text) {
    if (!text.startsWith('(') || !text.endsWith(')')) return null;
    var depth = 0;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (char == '(') depth++;
      if (char == ')') {
        depth--;
        if (depth == 0) {
          // The closing bracket must end the text; anything after it means the
          // condition is not the list the caller thinks it is.
          return i == text.length - 1 ? text.substring(1, i) : null;
        }
      }
    }
    return null;
  }

  /// Nesting limit for logical rules, mirroring the engine's own
  /// (`MAX_RULE_DEPTH` in the router). The engine refuses a table nested
  /// deeper than this, and a converter that kept walking would hit the stack
  /// first on a profile written to nest without end.
  static const int _maxRuleDepth = 8;

  /// Converts a Clash logical condition into the engine's nested child rules.
  ///
  /// Returns `null` for a condition this build cannot express: a malformed
  /// bracket list, a sub-rule type the engine has no equivalent for, a
  /// sub-rule naming a rule set that is not available, or nesting past
  /// [_maxRuleDepth]. The caller skips the whole rule then — a logical rule
  /// that matches on part of its condition silently routes traffic the
  /// profile meant to protect.
  static List<Map<String, dynamic>>? _parseLogicalRule(
    String condition, {
    required Set<String> availableRuleSets,
  }) {
    final children = _parseConditionList(condition, availableRuleSets, 1);
    if (children == null || children.isEmpty) return null;
    return children;
  }

  /// Copies the rule's target onto every child. The engine reads the target
  /// from the rule that decides, but a child is a rule as far as the config
  /// format is concerned, so each one has to carry a valid one.
  static List<Map<String, dynamic>> _attachOutbound(
    List<Map<String, dynamic>> rules,
    String outbound,
  ) {
    return [
      for (final rule in rules)
        {
          ...rule,
          'outbound': outbound,
          if (rule['rules'] case final List<dynamic> nested)
            'rules': _attachOutbound(
              nested.cast<Map<String, dynamic>>(),
              outbound,
            ),
        },
    ];
  }

  static List<Map<String, dynamic>>? _parseConditionList(
    String condition,
    Set<String> availableRuleSets,
    int depth,
  ) {
    if (depth > _maxRuleDepth) return null;
    final inner = _stripOuterParens(condition.trim());
    if (inner == null) return null;

    final children = <Map<String, dynamic>>[];
    for (final part in _splitRuleFields(inner)) {
      final piece = part.trim();
      if (piece.isEmpty) continue;
      final body = _stripOuterParens(piece);
      if (body == null) return null;
      final fields = _splitRuleFields(body);
      if (fields.length < 2) return null;
      final childType = _mapRuleType(fields[0].trim());
      // The payload may itself contain commas — a port list, a regex — and
      // each of them belongs to the condition's field, not to the list.
      final childPayload = fields.sublist(1).join(',').trim();
      if (childType == null) return null;

      if (childType == 'and' || childType == 'or' || childType == 'not') {
        final nested = _parseConditionList(
          childPayload,
          availableRuleSets,
          depth + 1,
        );
        if (nested == null || nested.isEmpty) return null;
        children.add({
          'type': childType,
          'payload': '',
          'process_name': null,
          'rules': nested,
        });
        continue;
      }

      if (childPayload.isEmpty) return null;
      if ((childType == 'rule_set' || childType == 'geosite') &&
          !availableRuleSets.contains(childPayload)) {
        return null;
      }
      children.add({
        'type': childType,
        'payload': childPayload,
        'process_name': null,
        if (fields
            .skip(2)
            .any((flag) => flag.trim().toLowerCase() == 'no-resolve'))
          'no_resolve': true,
      });
    }
    return children;
  }

  /// Maps a Clash rule type onto a corduit rule type.
  ///
  /// `null` means corduit has no matching rule type (`SCRIPT` and similar);
  /// the rule is skipped, because an unknown type would fail config
  /// validation and take the whole profile down with it.
  static String? _mapRuleType(String clashRuleType) {
    switch (clashRuleType.toUpperCase()) {
      case 'DOMAIN':
        return 'domain';
      case 'DOMAIN-SUFFIX':
        return 'domain_suffix';
      case 'DOMAIN-KEYWORD':
        return 'domain_keyword';
      case 'DOMAIN-REGEX':
        return 'domain_regex';
      case 'GEOIP':
        return 'geoip';
      case 'IP-CIDR':
      case 'IP-CIDR6':
        return 'ip_cidr';
      case 'SRC-IP-CIDR':
        return 'src_ip_cidr';
      case 'PROCESS-NAME':
        return 'process_name';
      case 'PROCESS-PATH':
        return 'process_path';
      case 'NETWORK':
        return 'network';
      case 'MATCH':
      case 'FINAL':
        return 'match';
      case 'RULE-SET':
        return 'rule_set';
      case 'GEOSITE':
        return 'geosite';
      case 'DST-PORT':
        return 'dst_port';
      case 'SRC-PORT':
        return 'src_port';
      case 'IN-PORT':
        return 'in_port';
      case 'IN-TYPE':
        return 'in_type';
      case 'IN-USER':
        return 'in_user';
      case 'IN-NAME':
        return 'in_name';
      case 'AND':
        return 'and';
      case 'OR':
        return 'or';
      case 'NOT':
        return 'not';
      default:
        return null;
    }
  }
}
