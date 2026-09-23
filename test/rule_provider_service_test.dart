import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:arcadia_plus/src/services/rule_provider_service.dart';

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
    sandbox = Directory.systemTemp.createTempSync(
      'arcadia_plus-rule-providers',
    );
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

    final report = await serviceWith(
      client,
    ).prepare('profile-1', httpProfile());

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

  test(
    'keeps plain line lists and drops comments and invalid entries',
    () async {
      final client = MockClient((request) async {
        return http.Response(
          '# comment\n'
          '10.0.0.0/8\n'
          '// another comment\n'
          '192.168.0.0/16\n'
          'not-a-cidr\n',
          200,
        );
      });

      final report = await serviceWith(
        client,
      ).prepare('profile-1', httpProfile(behavior: 'ipcidr'));

      final state = report.states.single;
      expect(state.ready, isTrue, reason: state.error ?? '');
      expect(state.entries, 2);
      expect(state.skipped, 1);
      expect(
        File(state.path!).readAsStringSync(),
        '10.0.0.0/8\n192.168.0.0/16\n',
      );
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

      final report = await serviceWith(
        client,
      ).prepare('profile-1', httpProfile());

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
    expect(state.error, contains('https'));
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
}
