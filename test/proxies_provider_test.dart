import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:arcadiaplus/src/providers/proxies_provider.dart';
import 'package:arcadiaplus/src/services/proxy_selection_events.dart';

import 'support/proxy_engine_fake.dart';

Future<void> flush() async {
  for (var i = 0; i < 15; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeEngine engine;
  late ProxiesProvider provider;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    engine = FakeEngine();
    provider = ProxiesProvider(engine: engine)..loadFromYaml(config());
  });
  tearDown(() {
    provider.dispose();
    engine.dispose();
  });
  test(
    'rapid selections serialize and publish only confirmed members',
    () async {
      await flush();
      engine.isReady = true;
      final gate = engine.selectGate = Completer<bool>();
      final first = provider.selectProxyInGroup('route', 'node1');
      final second = provider.selectProxyInGroup('route', 'node2');
      await flush();
      expect(engine.calls, ['node1']);
      expect(provider.getSelectedProxyForGroup('route'), 'node0');
      expect(provider.isSelecting('route'), isTrue);
      gate.complete(true);
      await Future.wait([first, second]);
      expect(engine.calls, ['node1', 'node2']);
      expect(provider.getSelectedProxyForGroup('route'), 'node2');
      expect(engine.selections['route'], 'node2');
      expect(provider.isSelecting('route'), isFalse);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'selected_proxy_route',
        ),
        'node2',
      );
    },
  );
  test(
    'a refused selection preserves the last member and reports failure',
    () async {
      await flush();
      engine
        ..isReady = true
        ..reject = true;
      engine.selections['route'] = 'node0';
      await provider.selectProxyInGroup('route', 'node1');
      expect(provider.getSelectedProxyForGroup('route'), 'node0');
      expect(provider.error, isNotNull);
      expect(provider.isSelecting('route'), isFalse);
    },
  );
  test(
    'a failed post-write read restores and verifies the core baseline',
    () async {
      await flush();
      engine.isReady = true;
      engine.selections['route'] = 'node2';
      var reads = 0;
      engine.onSelected = (group) async {
        if (++reads == 2) throw StateError('read interrupted');
        return engine.selections[group];
      };
      await provider.selectProxyInGroup('route', 'node1');
      expect(engine.calls, ['node1', 'node2']);
      expect(reads, 3);
      expect(provider.getSelectedProxyForGroup('route'), 'node2');
      expect(engine.selections['route'], 'node2');
      expect(provider.error, contains('Previous selection restored'));
    },
  );

  test(
    'failed rollback publishes the observed member and invalidates IP',
    () async {
      await flush();
      engine.isReady = true;
      engine.selections['route'] = 'node0';
      engine.onSelect = (group, proxy) async {
        if (proxy == 'node1') engine.selections[group] = proxy;
        return false;
      };
      final revision = ProxySelectionEvents.revision;
      await provider.selectProxyInGroup('route', 'node1');
      expect(engine.calls, ['node1', 'node0']);
      expect(provider.getSelectedProxyForGroup('route'), 'node1');
      expect(provider.error, contains('could not be restored'));
      expect(ProxySelectionEvents.revision, greaterThan(revision));
      expect(
        (await SharedPreferences.getInstance()).getString(
          'selected_proxy_route',
        ),
        'node1',
      );
    },
  );

  test(
    'unreadable recovery clears both checkmark and stale preference',
    () async {
      await provider.selectProxyInGroup('route', 'node0');
      engine.isReady = true;
      engine.selections['route'] = 'node0';
      var reads = 0;
      engine.onSelected = (group) async {
        if (++reads > 1) throw StateError('bridge unavailable');
        return engine.selections[group];
      };
      await provider.selectProxyInGroup('route', 'node1');
      expect(engine.calls, ['node1', 'node0']);
      expect(provider.getSelectedProxyForGroup('route'), isNull);
      expect(provider.error, contains('Core selection is unknown'));
      expect(
        (await SharedPreferences.getInstance()).getString(
          'selected_proxy_route',
        ),
        isNull,
      );
    },
  );

  test('startup sync uses the same verified recovery path', () async {
    await provider.selectProxyInGroup('route', 'node1');
    engine.isReady = true;
    engine.selections['route'] = 'node0';
    var reads = 0;
    engine.onSelected = (group) async {
      if (++reads == 2) throw StateError('read interrupted');
      return engine.selections[group];
    };
    await provider.syncSelectionsToRust();
    expect(engine.calls, ['node1', 'node0', 'node0']);
    expect(engine.selections['GLOBAL'], 'node0');
    expect(provider.getSelectedProxyForGroup('route'), 'node0');
    expect(provider.error, contains('Previous selection restored'));
  });

  test(
    'storage failure cannot hide a confirmed switch or escape unawaited work',
    () async {
      provider.dispose();
      provider = ProxiesProvider(
        engine: engine,
        preferences: () => Future.error(StateError('storage unavailable')),
      )..loadFromYaml(config());
      await flush();
      engine.isReady = true;
      final revision = ProxySelectionEvents.revision;
      await provider.selectProxyInGroup('route', 'node1');
      expect(provider.getSelectedProxyForGroup('route'), 'node1');
      expect(provider.error, contains('Could not save proxy preferences'));
      expect(ProxySelectionEvents.revision, greaterThan(revision));
      // This entry point deliberately does not return a Future to the widget.
      provider.loadFromYaml(
        '${config()}\n  - {name: alternate, type: select, proxies: [node0]}',
      );
      provider.selectGroup('alternate');
      await flush();
      expect(provider.error, isNotNull);
    },
  );

  test(
    'profile replacement prevents a stale rollback from reaching the core',
    () async {
      await flush();
      engine.isReady = true;
      engine.selections['route'] = 'node0';
      final gate = engine.selectGate = Completer<bool>();
      final operation = provider.selectProxyInGroup('route', 'node2');
      await flush();
      engine.isReady = false;
      provider.loadFromYaml(config(1));
      gate.complete(false);
      await operation;
      expect(engine.calls, ['node2']);
      expect(provider.getSelectedProxyForGroup('route'), 'node0');
    },
  );

  test('an unreadable baseline prevents a core mutation', () async {
    await flush();
    engine.isReady = true;
    engine.onSelected = (_) => Future.error(StateError('read unavailable'));
    await provider.selectProxyInGroup('route', 'node1');
    expect(engine.calls, isEmpty);
    expect(provider.getSelectedProxyForGroup('route'), isNull);
    expect(provider.error, contains('read unavailable'));
  });

  test(
    'a command throwing after mutation still restores the observed baseline',
    () async {
      await flush();
      engine.isReady = true;
      engine.selections['route'] = 'node0';
      engine.onSelect = (group, proxy) async {
        engine.selections[group] = proxy;
        if (proxy == 'node1') throw StateError('reply lost');
        return true;
      };
      await provider.selectProxyInGroup('route', 'node1');
      expect(engine.calls, ['node1', 'node0']);
      expect(engine.selections['route'], 'node0');
      expect(provider.getSelectedProxyForGroup('route'), 'node0');
      expect(provider.error, contains('Previous selection restored'));
    },
  );

  test('new profiles discard obsolete group and node selections', () async {
    await provider.selectProxyInGroup('route', 'node2');
    provider.loadFromYaml(config(1));
    expect(provider.getSelectedProxyForGroup('route'), 'node0');
    await provider.selectProxyInGroup('route', 'missing');
    expect(provider.getSelectedProxyForGroup('route'), 'node0');
    expect(
      () => provider.selectedProxies['route'] = 'missing',
      throwsUnsupportedError,
    );
  });
  test('batch and individual probes share a four-connection budget', () async {
    provider.loadFromYaml(config(16));
    await flush();
    engine.isReady = true;
    final batch = provider.testAllLatencies();
    final individual = provider.testLatency('node15');
    await flush();
    expect(engine.active, 4);
    while (provider.isTesting || engine.active > 0) {
      for (final probe in engine.measures.values.toList()) {
        if (!probe.isCompleted) probe.complete(23);
      }
      await flush();
    }
    await Future.wait([batch, individual]);
    expect(engine.peak, 4);
    expect(provider.latencyResults.length, 16);
    expect(provider.latencyResults.values.every((r) => r.isSuccess), isTrue);
  });
  test('cleared results cannot be repopulated by an older probe', () async {
    await flush();
    engine.isReady = true;
    final task = provider.testLatency('node1');
    await flush();
    provider.clearLatencies();
    engine.measures['node1']!.complete(10);
    await task;
    expect(provider.latencyResults, isEmpty);
  });
  test('probe failure remains failure without TCP fallback', () async {
    await flush();
    engine.isReady = true;
    final task = provider.testLatency('node1');
    await flush();
    engine.measures['node1']!.completeError(
      StateError('authentication failed'),
    );
    await task;
    expect(provider.getLatency('node1')!.isSuccess, isFalse);
    expect(provider.getLatency('node1')!.latencyMs, isNull);
    expect(engine.measures.length, 1);
  });
  test(
    'reloading while a selection awaits does not restore stale UI',
    () async {
      await flush();
      engine.isReady = true;
      final gate = engine.selectGate = Completer<bool>();
      final task = provider.selectProxyInGroup('route', 'node2');
      await flush();
      engine.isReady = false;
      provider.loadFromYaml(config(1));
      gate.complete(true);
      await task;
      expect(provider.getSelectedProxyForGroup('route'), 'node0');
    },
  );
  test('dispose detaches listeners and ignores late replies', () async {
    final owner = ProxiesProvider(engine: engine)..loadFromYaml(config());
    await flush();
    engine.isReady = true;
    final task = owner.testLatency('node0');
    await flush();
    var notifications = 0;
    owner.addListener(() => notifications++);
    owner.dispose();
    engine.measures['node0']!.complete(12);
    await task;
    expect(notifications, 0);
    provider.dispose();
    expect(engine.hasSubscribers, isFalse);
    provider = ProxiesProvider(engine: engine);
  });
}
