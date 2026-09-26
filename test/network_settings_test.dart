import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/services/platform_proxy_service.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';

void main() {
  group('NetworkSettings bypass defaults', () {
    test('a fresh record carries the local ranges', () {
      final settings = NetworkSettings();
      expect(settings.bypassDomains, NetworkSettings.defaultBypassDomains);
      expect(
        settings.bypassRevision,
        NetworkSettings.bypassDefaultsRevision,
        reason: 'a new install is already up to date',
      );
    });

    test('a record written before the revision existed is migrated once', () {
      final stored = NetworkSettings.fromJson({
        'systemProxy': false,
        'bypassDomains': ['example.com'],
        'tunEnabled': false,
      });

      expect(stored.bypassRevision, 0);
      final migrated = stored.withDefaultBypassDomains();

      expect(migrated.bypassRevision, NetworkSettings.bypassDefaultsRevision);
      expect(migrated.bypassDomains.take(1), [
        'example.com',
      ], reason: 'the user\'s own entries keep their place');
      for (final entry in NetworkSettings.defaultBypassDomains) {
        expect(migrated.bypassDomains, contains(entry));
      }
    });

    test('a record already at the current revision is not migrated again', () {
      final stored = NetworkSettings.fromJson({
        'systemProxy': true,
        'bypassDomains': ['example.com'],
        'tunEnabled': false,
        'bypassRevision': NetworkSettings.bypassDefaultsRevision,
      });

      // This is the condition `StorageService.getNetworkSettings` gates the
      // merge on, so an entry deleted after the last migration stays deleted.
      expect(
        stored.bypassRevision >= NetworkSettings.bypassDefaultsRevision,
        isTrue,
      );
    });
  });

  group('bypass entries for platforms without CIDR support', () {
    test('octet-aligned blocks become wildcards', () {
      expect(PlatformProxyService.expandBypassForGlobMatching(['10.0.0.0/8']), [
        '10.*',
      ]);
      expect(
        PlatformProxyService.expandBypassForGlobMatching(['192.168.0.0/16']),
        ['192.168.*'],
      );
      expect(
        PlatformProxyService.expandBypassForGlobMatching(['127.0.0.1/32']),
        ['127.0.0.1'],
      );
    });

    test('172.16.0.0/12 is covered exactly, with no over-matching', () {
      final patterns = PlatformProxyService.expandBypassForGlobMatching([
        '172.16.0.0/12',
      ]);

      expect(patterns.first, '172.16.*');
      expect(patterns.last, '172.31.*');
      expect(patterns, hasLength(16));
    });

    test('names, globs and literals pass through, duplicates are dropped', () {
      expect(
        PlatformProxyService.expandBypassForGlobMatching([
          'localhost',
          ' *.lan ',
          '::1',
          'localhost',
        ]),
        ['localhost', '*.lan', '::1'],
      );
    });

    test(
      'a block with no exact wildcard form is skipped, not approximated',
      () {
        expect(
          PlatformProxyService.expandBypassForGlobMatching(['192.168.1.0/26']),
          isNotEmpty,
          reason: 'a /26 falls inside one octet and can be enumerated',
        );
        expect(
          PlatformProxyService.expandBypassForGlobMatching(['10.0.0.0/2']),
          isEmpty,
          reason: 'no wildcard covers a /2 without matching half the internet',
        );
      },
    );
  });
}
