import 'dart:async';

import 'package:arcadiaplus/src/providers/dns_settings_provider.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'apply waits for queued writes and only observes persisted values',
    () async {
      final gate = Completer<void>();
      final saved = <DnsSettings>[];
      final provider = DnsSettingsProvider(
        read: () async => DnsSettings(),
        write: (settings) async {
          if (saved.isEmpty) await gate.future;
          saved.add(settings);
        },
      );
      addTearDown(provider.dispose);
      final first = provider.setPreferEncryptedDns(true);
      final second = provider.setUseRecursiveResolver(true);
      var applied = false;
      final application = provider.waitUntilSaved().then((success) {
        applied = success;
        expect(provider.settings, same(saved.last));
      });
      await Future<void>.delayed(Duration.zero);
      expect(provider.isSaving, true);
      expect(provider.preferEncryptedDns, false);
      expect(applied, false);
      gate.complete();
      await Future.wait([first, second, application]);
      expect(applied, true);
      expect(provider.isSaving, false);
      expect(saved.last.preferEncryptedDns, true);
      expect(saved.last.useRecursiveResolver, true);
    },
  );

  test(
    'strict validation sees loaded settings and preceding queued edits',
    () async {
      final loaded = Completer<DnsSettings>();
      final saved = <DnsSettings>[];
      final provider = DnsSettingsProvider(
        read: () => loaded.future,
        write: (settings) async => saved.add(settings),
        validateStrict: (settings) async {
          expect(settings.nameservers, ['tcp://private.example:8080']);
          throw const FormatException('Private DNS has no encrypted endpoint');
        },
      );
      addTearDown(provider.dispose);
      final edit = provider.setNameservers(['tcp://private.example:8080']);
      final strict = provider.setRequireEncryptedDns(true);
      loaded.complete(DnsSettings(useRecursiveResolver: true));
      await Future.wait([edit, strict]);
      expect(provider.requireEncryptedDns, false);
      expect(provider.useRecursiveResolver, true);
      expect(provider.saveError, contains('Private DNS'));
      expect(await provider.waitUntilSaved(), false);
      expect(saved, hasLength(1));
      // Reaffirming the last successfully saved mode can recover a failed attempt.
      await provider.setRequireEncryptedDns(false);
      expect(provider.saveError, isNull);
      expect(await provider.waitUntilSaved(), true);
    },
  );

  test('a failed save blocks apply and releases the pending state', () async {
    final provider = DnsSettingsProvider(
      read: () async => DnsSettings(),
      write: (_) async => throw StateError('disk full'),
    );
    addTearDown(provider.dispose);
    await provider.setPreferEncryptedDns(true);
    expect(await provider.waitUntilSaved(), false);
    expect(provider.preferEncryptedDns, false);
    expect(provider.isSaving, false);
  });
}
