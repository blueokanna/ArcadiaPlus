import 'dart:convert';
import 'package:yaml/yaml.dart';
import 'package:veloguard/src/services/storage_service.dart';

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

/// Converts Clash YAML configuration to VeloGuard JSON format
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

  /// Convert Clash YAML config to VeloGuard JSON config
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
    Map<String, String>? ruleProviderPaths,
    void Function(String message)? onWarning,
  }) {
    try {
      final yamlMap = loadYaml(yamlContent);
      if (yamlMap == null) {
        throw Exception('Empty YAML content');
      }

      final config = _convertToMap(yamlMap);
      final veloguardConfig = _convertClashToVeloGuard(
        config,
        generalSettings: generalSettings,
        dnsSettings: dnsSettings,
        recursiveDnsAddress: recursiveDnsAddress,
        ruleProviderPaths: ruleProviderPaths,
        onWarning: onWarning,
      );

      return jsonEncode(veloguardConfig);
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

  /// Convert Clash config format to VeloGuard config format
  static Map<String, dynamic> _convertClashToVeloGuard(
    Map<String, dynamic> clash, {
    GeneralSettings? generalSettings,
    DnsSettings? dnsSettings,
    String? recursiveDnsAddress,
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
    // Use generalSettings if provided, otherwise fall back to YAML values
    final httpPort = generalSettings?.httpPort ?? clash['port'] ?? 7890;
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

    final mode = generalSettings?.mode ?? clash['mode'] ?? 'rule';
    final logLevel = generalSettings?.logLevel ?? clash['log-level'] ?? 'info';

    return {
      'port': httpPort,
      'socks_port': socksPort,
      'redir_port': clash['redir-port'],
      'tproxy_port': clash['tproxy-port'],
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
  static Map<String, dynamic> _extractDnsConfig(
    Map<String, dynamic> clash, {
    DnsSettings? dnsSettings,
    String? recursiveDnsAddress,
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

    // A running RecurseX front-end stays authoritative: put it first and
    // every forwarded query becomes a recursive one, with the configured
    // upstreams kept behind it as fallbacks.
    final nameservers = recursiveDnsAddress == null
        ? effectiveConfigured
        : [recursiveDnsAddress, ...effectiveConfigured];

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

    return {
      'enable': override ? dnsSettings.enable : (dns['enable'] ?? true),
      'listen': override
          ? dnsSettings.listen
          : (dns['listen'] ?? '127.0.0.1:53'),
      'nameservers': nameservers,
      'fallback': fallback,
      'enhanced_mode': override
          ? dnsSettings.dnsMode
          : (dns['enhanced-mode'] ?? 'fake-ip'),
      'nameserver_policy': policy,
    };
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

  /// Maps a Clash proxy type onto a corduit outbound type.
  ///
  /// `null` means corduit has no way to build this protocol (shadowsocksr,
  /// hysteria v1 and shadowquic today); such a node is dropped from the
  /// outbound list and every reference to it is rewritten.
  static String? _mapProxyType(String clashType) {
    switch (clashType) {
      case 'ss':
      case 'shadowsocks':
        return 'shadowsocks';
      case 'vmess':
        return 'vmess';
      case 'vless':
        return 'vless';
      case 'trojan':
        return 'trojan';
      case 'http':
        return 'http';
      case 'socks5':
      case 'socks':
        return 'socks5';
      case 'hysteria2':
      case 'hy2':
        return 'hysteria2';
      case 'wireguard':
        return 'wireguard';
      case 'tuic':
        return 'tuic';
      default:
        return null;
    }
  }

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
        final parts = rule.split(',');
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

          rules.add({
            'rule_type': mappedType,
            'payload': payload,
            'outbound': resolveTarget(outbound, rule),
            'process_name': null,
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

  /// Maps a Clash rule type onto a corduit rule type.
  ///
  /// `null` means corduit has no matching rule type (GEOSITE and similar);
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
      case 'MATCH':
      case 'FINAL':
        return 'match';
      case 'RULE-SET':
        return 'rule_set';
      case 'DST-PORT':
        return 'dst_port';
      case 'SRC-PORT':
        return 'src_port';
      default:
        return null;
    }
  }
}
