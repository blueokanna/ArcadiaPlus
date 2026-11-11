import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:arcadiaplus/src/providers/proxies_provider.dart';
import 'package:arcadiaplus/src/services/proxy_engine_service.dart';
import 'package:arcadiaplus/src/services/proxy_selection_service.dart';

import 'support/proxy_engine_fake.dart';

Future<void> flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeEngine native;
  late ConfiguredProxyEngine engine;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    native = FakeEngine()..isReady = true;
    engine = ConfiguredProxyEngine(native);
  });
  tearDown(() {
    engine.dispose();
    native.dispose();
  });

  test(
    'loaded FFI does not authorize selection before configuration',
    () async {
      final provider = ProxiesProvider(engine: engine)..loadFromYaml(config());
      addTearDown(provider.dispose);
      await provider.selectProxyInGroup('route', 'node2');
      await provider.testAllLatencies();
      expect(native.calls, isEmpty);
      expect(native.measures, isEmpty);
      expect(provider.error, isNull);
      expect(provider.getSelectedProxyForGroup('route'), 'node2');
      expect(
        (await SharedPreferences.getInstance()).getString(
          'selected_proxy_route',
        ),
        'node2',
      );

      final installation = Completer<void>();
      final task = engine.configure(null, (_) => installation.future);
      await flush();
      expect(provider.canTestLatency, isFalse);
      expect(native.calls, isEmpty);
      installation.complete();
      await task;
      await flush();
      expect(provider.canTestLatency, isTrue);
      expect(native.selections['route'], 'node2');
      expect(provider.error, isNull);
    },
  );

  test('a failed install remains unavailable and can be retried', () async {
    await expectLater(
      engine.configure('a', (_) async => throw StateError('bad config')),
      throwsStateError,
    );
    expect(engine.isReady, isFalse);
    await engine.configure('a', (_) async {});
    expect(engine.supportsProfile('a'), isTrue);
    expect(engine.supportsProfile('b'), isFalse);
    await engine.stop(() async {});
    expect(engine.isReady, isFalse);
  });

  test(
    'selection rollback finishes before a configuration replacement',
    () async {
      await engine.configure('a', (_) async {});
      native.selections['route'] = 'node0';
      final gate = native.selectGate = Completer<bool>();
      final selection = ProxySelectionService(engine)
          .select('route', 'node1', isCurrent: () => true);
      await flush();
      var replaced = false;
      final reload = engine.configure('b', (_) async {
        replaced = true;
        native.selections['route'] = 'new-profile-node';
      });
      await flush();
      expect(replaced, isFalse);
      gate.complete(false);
      expect((await selection)!.member, 'node0');
      await reload;
      expect(native.selections['route'], 'new-profile-node');
    },
  );

  test(
    'a preview of another profile cannot mutate the configured engine',
    () async {
      await engine.configure('running-profile', (_) async {});
      final provider = ProxiesProvider(engine: engine)..loadFromYaml(config());
      addTearDown(provider.dispose);
      await provider.selectProxyInGroup('route', 'node1');
      expect(provider.canTestLatency, isFalse);
      expect(native.calls, isEmpty);
      expect(provider.getSelectedProxyForGroup('route'), 'node1');
    },
  );

  test('automatic strategies never receive manual selector writes', () async {
    final provider = ProxiesProvider(engine: native)
      ..loadFromYaml('''
${config()}
  - {name: automatic, type: url-test, proxies: [node0, node1]}
  - {name: recovery, type: fallback, proxies: [node0, node1]}
  - {name: balanced, type: load-balance, proxies: [node0, node1]}
''');
    addTearDown(provider.dispose);
    await flush();
    for (final group in ['automatic', 'recovery', 'balanced']) {
      await provider.selectProxyInGroup(group, 'node1');
      expect(provider.getSelectedProxyForGroup(group), isNull);
      expect(native.selections.containsKey(group), isFalse);
    }
    expect(provider.error, isNull);
  });
}
