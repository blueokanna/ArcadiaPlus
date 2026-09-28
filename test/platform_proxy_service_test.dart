import 'package:flutter_test/flutter_test.dart';

import 'package:arcadiaplus/src/services/platform_proxy_service.dart';

void main() {
  group('WinINET ProxyEnable parsing', () {
    test('reads the hexadecimal form reg query prints', () {
      // A REG_DWORD comes back from `reg query` as 0x1 when the proxy is on,
      // which is the exact case the old string comparison read as "off".
      expect(PlatformProxyService.proxyEnableIsOn('0x1'), isTrue);
      expect(PlatformProxyService.proxyEnableIsOn('0x0'), isFalse);
      expect(PlatformProxyService.proxyEnableIsOn('0X1'), isTrue);
    });

    test('reads the decimal form', () {
      expect(PlatformProxyService.proxyEnableIsOn('1'), isTrue);
      expect(PlatformProxyService.proxyEnableIsOn('0'), isFalse);
      expect(PlatformProxyService.proxyEnableIsOn(' 1 '), isTrue);
    });

    test('treats anything that is not exactly one as off', () {
      expect(PlatformProxyService.proxyEnableIsOn(null), isFalse);
      expect(PlatformProxyService.proxyEnableIsOn(''), isFalse);
      expect(PlatformProxyService.proxyEnableIsOn('2'), isFalse);
      expect(PlatformProxyService.proxyEnableIsOn('0x'), isFalse);
      expect(PlatformProxyService.proxyEnableIsOn('0x10'), isFalse);
      expect(PlatformProxyService.proxyEnableIsOn('true'), isFalse);
    });
  });
}
