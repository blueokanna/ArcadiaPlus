import 'dart:convert';
import 'dart:io';

import 'package:arcadiaplus/src/services/windows_system_proxy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/windows_proxy');
  late Directory directory;
  late File snapshot;
  late WindowsSystemProxy proxy;
  late Map<String, Object> state;
  var failApply = false;
  const original = <String, Object>{
    'flags': 13,
    'server': 'old.example:8080',
    'bypass': '*.internal',
    'autoConfigUrl': 'https://intranet.example/proxy.pac',
  };

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('arcadia-proxy-test');
    snapshot = File('${directory.path}/snapshot.json');
    state = Map.of(original);
    failApply = false;
    proxy = WindowsSystemProxy(
      channel: channel,
      snapshotFile: () async => snapshot,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'read') return state;
          if (failApply) throw PlatformException(code: 'access_denied');
          state = Map<String, Object>.from(call.arguments as Map);
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await directory.delete(recursive: true);
  });

  test(
    'enable, change port and restore PAC/WPAD across a new service instance',
    () async {
      await proxy.enable('127.0.0.1:7890', '<local>;10.*');
      expect(state['flags'], 3);
      expect(state['autoConfigUrl'], isEmpty);
      await proxy.enable('127.0.0.1:7891', '<local>');
      expect(jsonDecode(await snapshot.readAsString()), original);
      final restarted = WindowsSystemProxy(
        channel: channel,
        snapshotFile: () async => snapshot,
      );
      await restarted.disable();
      expect(state, original);
      expect(await snapshot.exists(), isFalse);
    },
  );

  test('a failed restore retains the recovery snapshot', () async {
    await proxy.enable('127.0.0.1:7890', '<local>');
    failApply = true;
    await expectLater(proxy.disable(), throwsA(isA<PlatformException>()));
    expect(await snapshot.exists(), isTrue);
    expect(WindowsSystemProxy.enabled(state), isTrue);
  });

  test('overlapping enable and disable transactions are serialized', () async {
    await Future.wait([
      proxy.enable('127.0.0.1:7890', '<local>'),
      proxy.disable(),
    ]);
    expect(state, original);
  });

  test('ownership checks require an enabled local endpoint', () async {
    state = {...original, 'flags': 3, 'server': 'remote.example:7890'};
    expect(await proxy.targets(7890), isFalse);
    state = {...state, 'server': 'http=127.0.0.1:7890;https=127.0.0.1:7890'};
    expect(await proxy.targets(7890), isTrue);
    state = {...state, 'flags': 1};
    expect(await proxy.targets(7890), isFalse);
  });

  test('a corrupt recovery snapshot prevents changing system state', () async {
    await snapshot.writeAsString('{broken');
    await expectLater(
      proxy.enable('127.0.0.1:7890', '<local>'),
      throwsA(isA<FormatException>()),
    );
    expect(state, original);
    expect(await snapshot.readAsString(), '{broken');
  });

  test('partial native updates are detected and rolled back', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'read') return state;
          final requested = Map<String, Object>.from(call.arguments as Map);
          state = requested['flags'] == 3
              ? {...requested, 'flags': 11} // PAC remained enabled.
              : requested;
          return null;
        });
    await expectLater(
      proxy.enable('127.0.0.1:7890', '<local>'),
      throwsA(isA<FileSystemException>()),
    );
    expect(state, original);
    expect(await snapshot.exists(), isTrue);
  });
}
