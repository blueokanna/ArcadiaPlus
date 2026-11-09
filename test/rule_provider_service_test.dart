import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:arcadiaplus/src/services/rule_provider_service.dart';

String httpProfile({
  String behavior = 'domain',
  String url = 'https://rules.example.com/reject.yaml',
  int interval = 86400,
}) =>
    '''
rule-providers:
  reject:
    type: http
    behavior: $behavior
    url: "$url"
    interval: $interval
''';

String fileProfile(String path, {String behavior = 'ipcidr'}) =>
    '''
rule-providers:
  manual:
    type: file
    behavior: $behavior
    path: "$path"
''';

void main() {
  late Directory sandbox;
  late Directory support;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('arcadiaplus-rule-providers');
    support = Directory('${sandbox.path}/support')..createSync(recursive: true);
  });

  tearDown(() {
    if (sandbox.existsSync()) {
      sandbox.deleteSync(recursive: true);
    }
  });

  RuleProviderService serviceWith(MockClient client) =>
      RuleProviderService(client: client, storageRoot: () async => support);

  test('unwraps a YAML payload into the line format the engine parses', () async {
    final requested = <Uri>[];
    final client = MockClient((request) async {
      requested.add(request.url);
      return http.Response(
        'payload:\n'
        '  - "+.google.com"\n'
        '  - "full:example.org"\n'
        '  - "keyword:doubleclick"\n',
        200,
        headers: {'etag': 'W/"v1"'},
      );
    });

    final report = await serviceWith(client)
        .prepare('profile-1', httpProfile());

    expect(report.states, hasLength(1));
    final state = report.states.single;
    expect(state.ready, isTrue, reason: state.error ?? '');
    expect(state.entries, 3);

    final lines = File(state.path!).readAsStringSync().split('\n');
    expect(lines.first, '+.google.com');
    expect(lines, contains('full:example.org'));
    expect(lines, contains('keyword:doubleclick'));

    final metaFile = File(
      '${File(state.path!).parent.path}${Platform.pathSeparator}reject.meta.json',
    );
    final meta =
        jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;
    expect(meta['etag'], 'W/"v1"');
    expect(requested, hasLength(1));
  });

  test('keeps plain line lists and removes only comments', () async {
    final client = MockClient((request) async {
      return http.Response(
        '# comment\n'
        '10.0.0.0/8\n'
        '// another comment\n'
        '192.168.0.0/16\n',
        200,
      );
    });

    final report = await serviceWith(client)
        .prepare('profile-1', httpProfile(behavior: 'ipcidr'));

    final state = report.states.single;
    expect(state.ready, isTrue, reason: state.error ?? '');
    expect(state.entries, 2);
    expect(state.skipped, 0);
    expect(
      File(state.path!).readAsStringSync(),
      '10.0.0.0/8\n192.168.0.0/16\n',
    );
  });

  test('partial refresh keeps the complete previous set', () async {
    var calls = 0;
    final service = serviceWith(
      MockClient(
        (_) async => http.Response(
          calls++ == 0 ? '10.0.0.0/8\n' : '192.168.0.0/16\ninvalid-cidr\n',
          200,
        ),
      ),
    );
    addTearDown(service.dispose);
    final first = await service.prepare(
      'partial',
      httpProfile(behavior: 'ipcidr'),
    );
    final second = await service.prepare(
      'partial',
      httpProfile(behavior: 'ipcidr'),
      force: true,
    );
    expect(second.paths, first.paths);
    expect(second.states.single.error, contains('incomplete rule set'));
    expect(File(second.paths['reject']!).readAsStringSync(), '10.0.0.0/8\n');
  });

  for (final invalid in [
    '<html>error</html>',
    'full:',
    '+.',
    'a..example',
    'https://example.com',
  ]) {
    test(
      'invalid domain payload cannot replace the last good set: $invalid',
      () async {
        var calls = 0;
        final service = serviceWith(
          MockClient(
            (_) async => http.Response(
              calls++ == 0 ? 'safe.example\n' : 'new.example\n$invalid\n',
              200,
            ),
          ),
        );
        addTearDown(service.dispose);
        final first = await service.prepare('domain', httpProfile());
        final second = await service.prepare(
          'domain',
          httpProfile(),
          force: true,
        );
        expect(second.paths, first.paths);
        expect(second.states.single.error, contains('incomplete rule set'));
      },
    );
  }

  test(
    'legacy partial caches are not reused as complete routing data',
    () async {
      final service = serviceWith(
        MockClient((_) async => http.Response('safe.example\n', 200)),
      );
      addTearDown(service.dispose);
      final first = await service.prepare('legacy-partial', httpProfile());
      final metadata = File(
        '${File(first.paths['reject']!).parent.path}/reject.meta.json',
      );
      final stored =
          jsonDecode(await metadata.readAsString()) as Map<String, dynamic>;
      stored['skipped'] = 1;
      await metadata.writeAsString(jsonEncode(stored));
      final offline = await service.prepare(
        'legacy-partial',
        httpProfile(),
        allowNetwork: false,
      );
      expect(offline.paths, isEmpty);
      expect(offline.states.single.ready, false);
    },
  );

  test('copies a local provider into the cache', () async {
    final manual = File('${sandbox.path}${Platform.pathSeparator}manual.txt')
      ..writeAsStringSync('198.18.0.0/15\n');

    final report = await serviceWith(
      MockClient((request) async => http.Response('unused', 404)),
    ).prepare('profile-1', fileProfile(manual.path.replaceAll(r'\', '/')));

    final state = report.states.single;
    expect(state.ready, isTrue, reason: state.error ?? '');
    expect(state.entries, 1);
    expect(File(state.path!).readAsStringSync(), '198.18.0.0/15\n');
  });

  test('does not re-download a provider before its interval elapses', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response('payload:\n  - example.com\n', 200);
    });

    final service = serviceWith(client);
    await service.prepare('profile-1', httpProfile());
    expect(calls, 1);

    await service.prepare('profile-1', httpProfile());
    expect(calls, 1, reason: 'interval has not elapsed yet');

    await service.prepare('profile-1', httpProfile(), force: true);
    expect(calls, 2);
  });

  test('reuses the cached copy when the refresh fails', () async {
    var fail = false;
    final client = MockClient((request) async {
      if (fail) {
        return http.Response('upstream unavailable', 502);
      }
      return http.Response('payload:\n  - example.com\n', 200);
    });

    final service = serviceWith(client);
    final first = await service.prepare('profile-1', httpProfile());
    final cached = first.paths['reject'];
    expect(cached, isNotNull);

    fail = true;
    final second = await service.prepare(
      'profile-1',
      httpProfile(),
      force: true,
    );
    final state = second.states.single;
    expect(state.path, cached, reason: 'the last good copy stays in use');
    expect(state.error, contains('502'));
  });

  test(
    'reports a provider that never downloaded instead of inventing one',
    () async {
      final client = MockClient((request) async => http.Response('nope', 404));

      final report = await serviceWith(client)
          .prepare('profile-1', httpProfile());

      final state = report.states.single;
      expect(state.ready, isFalse);
      expect(report.paths.containsKey('reject'), isFalse);
      expect(report.failed, hasLength(1));
    },
  );

  test('refuses non-TLS sources', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response('payload: []', 200);
    });

    final report = await serviceWith(client).prepare(
      'profile-1',
      httpProfile(url: 'http://rules.example.com/reject.yaml'),
    );

    final state = report.states.single;
    expect(state.ready, isFalse);
    expect(state.error, contains('HTTPS'));
    expect(calls, 0);
  });

  test('reuses an unmodified rule set after a 304 response', () async {
    final client = MockClient((request) async {
      if (request.headers['If-None-Match'] != null) {
        return http.Response('', 304);
      }
      return http.Response(
        'payload:\n  - example.com\n',
        200,
        headers: {'etag': 'W/"v2"'},
      );
    });

    final service = serviceWith(client);
    final first = await service.prepare('profile-1', httpProfile());
    final second = await service.prepare(
      'profile-1',
      httpProfile(),
      force: true,
    );

    expect(second.paths['reject'], first.paths['reject']);
    expect(second.states.single.updatedAt, isNotNull);
  });

  test('parse keeps well-formed specs and reports malformed ones', () {
    final warnings = <String>[];
    final specs = RuleProviderSpec.parse({
      'ok': {'type': 'http', 'behavior': 'domain', 'url': 'https://a/b'},
      'bad-type': {'type': 'inline', 'behavior': 'domain'},
      'bad-behavior': {
        'type': 'http',
        'behavior': 'geosite',
        'url': 'https://a/b',
      },
      'no-url': {'type': 'http', 'behavior': 'domain'},
      'tiny-interval': {
        'type': 'http',
        'behavior': 'domain',
        'url': 'https://a/b',
        'interval': 10,
      },
    }, onWarning: warnings.add);

    expect(specs.map((spec) => spec.name), contains('ok'));
    expect(specs.map((spec) => spec.name), contains('tiny-interval'));
    expect(
      specs.firstWhere((spec) => spec.name == 'tiny-interval').intervalSeconds,
      60,
    );
    expect(specs, hasLength(2));
    expect(warnings, hasLength(4));
  });

  test('MRS rule sets are dropped with a reason instead of half-loading', () {
    final warnings = <String>[];
    final specs = RuleProviderSpec.parse({
      // Declared explicitly...
      'declared': {
        'type': 'http',
        'behavior': 'domain',
        'url': 'https://a/b',
        'format': 'mrs',
      },
      // ...and by the extension alone, which is how most profiles write it.
      'by-extension': {
        'type': 'http',
        'behavior': 'domain',
        'url': 'https://cdn.example.com/geosite/cn.mrs',
      },
      'text-is-fine': {
        'type': 'http',
        'behavior': 'domain',
        'url': 'https://cdn.example.com/geosite/cn.txt',
        'format': 'text',
      },
      'unknown-format': {
        'type': 'http',
        'behavior': 'domain',
        'url': 'https://a/b',
        'format': 'sing-box',
      },
    }, onWarning: warnings.add);

    expect(specs.map((spec) => spec.name), contains('text-is-fine'));
    expect(specs, hasLength(1));
    expect(
      warnings.where((warning) => warning.contains('MRS')),
      hasLength(2),
      reason: 'both the explicit format and the .mrs extension are reported',
    );
    expect(warnings.join('\n'), contains('sing-box'));
  });

  test(
    'a binary payload that arrives anyway is reported, not written',
    () async {
      // A packed rule set that did not announce itself (no `format`, no .mrs
      // in the URL): the raw bytes are a NUL-bearing blob. The service must
      // report it instead of writing a file of mojibake that matches nothing.
      final file = File('${sandbox.path}/packed.rules');
      file.writeAsBytesSync(<int>[0x4D, 0x52, 0x53, 0x00, 0x01, 0x80, 0xFF]);

      final report =
          await serviceWith(
            MockClient((request) async => http.Response('unused', 500)),
          ).prepare(
            'profile-1',
            fileProfile(file.path.replaceAll(r'\', '/'), behavior: 'domain'),
          );

      final state = report.states.single;
      expect(state.ready, isFalse);
      expect(state.entries, 0);
      expect(state.error, contains('binary'));
      expect(report.paths, isEmpty);
    },
  );
  test(
    'changing a source URL invalidates fresh cache and conditional headers',
    () async {
      final requests = <http.Request>[];
      final service = serviceWith(
        MockClient((request) async {
          requests.add(request);
          return http.Response(
            'payload: ["${request.url.host}"]',
            200,
            headers: {'etag': 'old-source'},
          );
        }),
      );
      await service.prepare('source-change', httpProfile());
      final report = await service.prepare(
        'source-change',
        httpProfile(url: 'https://new.example/rules'),
      );
      expect(requests, hasLength(2));
      expect(requests.last.headers.containsKey('if-none-match'), isFalse);
      expect(
        File(report.paths['reject']!).readAsStringSync(),
        contains('new.example'),
      );
    },
  );

  test(
    'invalid refresh retains the previous usable rules and reports failure',
    () async {
      var request = 0;
      final service = serviceWith(
        MockClient(
          (_) async => http.Response(
            request++ == 0 ? 'payload: ["safe.example"]' : 'payload: []',
            200,
          ),
        ),
      );
      final before = await service.prepare('last-good', httpProfile());
      final after = await service.prepare(
        'last-good',
        httpProfile(),
        force: true,
      );
      expect(after.paths, before.paths);
      expect(after.states.single.error, contains('no usable rules'));
      expect(File(before.paths['reject']!).existsSync(), isTrue);
    },
  );

  test(
    'HTTPS downgrade is refused before sending an insecure request',
    () async {
      var requests = 0;
      final service = serviceWith(
        MockClient((request) async {
          requests++;
          return http.Response(
            '',
            302,
            headers: {'location': 'http://unsafe.example/rules'},
          );
        }),
      );
      final report = await service.prepare('redirect', httpProfile());
      expect(requests, 1);
      expect(report.states.single.ready, isFalse);
      expect(report.states.single.error, contains('HTTPS'));
    },
  );

  for (final invalid in [
    'payload: ["unfinished"',
    'payload: {domain: example.com}',
    'payload: [true, 123]',
    'payload: [{domain: example.com}]',
    'payload: [""]',
    '["example.com"]',
  ]) {
    test('malformed structured refresh preserves cache: $invalid', () async {
      var calls = 0;
      final service = serviceWith(
        MockClient(
          (_) async => http.Response(
            calls++ == 0 ? 'payload: ["safe.example"]' : invalid,
            200,
          ),
        ),
      );
      addTearDown(service.dispose);
      final before = await service.prepare('structured', httpProfile());
      final after = await service.prepare(
        'structured',
        httpProfile(),
        force: true,
      );
      expect(after.paths, before.paths);
      expect(after.states.single.error, contains('payload'));
      expect(File(after.paths['reject']!).readAsStringSync(), 'safe.example\n');
    });
  }

  test('long comment headers do not hide a YAML payload', () async {
    final service = serviceWith(
      MockClient(
        (_) async => http.Response(
          '${'# provider metadata\n' * 300}payload:\n  - "+.bilibili.com"\n',
          200,
        ),
      ),
    );
    addTearDown(service.dispose);
    final report = await service.prepare('header', httpProfile());
    expect(report.states.single.entries, 1);
    expect(
      File(report.paths['reject']!).readAsStringSync(),
      '+.bilibili.com\n',
    );
  });

  test('validates CIDR addresses and prefix lengths before caching', () async {
    final service = serviceWith(
      MockClient(
        (_) async => http.Response(
          'payload:\n'
          '  - "999.1.2.3/24"\n'
          '  - "192.168.0.0/33"\n'
          '  - "2001:db8::/129"\n'
          '  - ":::/64"\n'
          '  - "192.168.0.0/16"\n'
          '  - "2001:db8::/32"\n',
          200,
        ),
      ),
    );
    addTearDown(service.dispose);
    final report = await service.prepare(
      'cidr',
      httpProfile(behavior: 'ipcidr'),
    );
    expect(report.states.single.ready, isFalse);
    expect(report.paths, isEmpty);
    expect(report.states.single.error, contains('incomplete rule set'));
    expect(report.states.single.error, contains('4 unsupported entries'));
  });

  test(
    'concurrent refreshes share the committed cache without racing files',
    () async {
      var requests = 0;
      final service = serviceWith(
        MockClient((_) async {
          requests++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return http.Response('payload: ["safe.example"]', 200);
        }),
      );
      final reports = await Future.wait([
        service.prepare('concurrent', httpProfile()),
        service.prepare('concurrent', httpProfile()),
      ]);
      expect(requests, 1);
      expect(reports.first.paths, reports.last.paths);
    },
  );

  test('profile dot segments cannot escape the rule cache directory', () async {
    final service = serviceWith(
      MockClient((_) async => http.Response('example.org', 200)),
    );
    final report = await service.prepare('..', httpProfile());
    final directory = File(report.paths['reject']!).parent;
    expect(
      directory.parent.uri.pathSegments.where((s) => s.isNotEmpty).last,
      'rule-providers',
    );
    expect(
      directory.uri.pathSegments.where((s) => s.isNotEmpty).last,
      startsWith('key_'),
    );
  });
}
