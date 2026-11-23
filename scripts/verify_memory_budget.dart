import 'dart:convert';
import 'dart:io';

import 'package:arcadiaplus/main.dart' as app;
import 'package:arcadiaplus/src/rust/api.dart' as core;
import 'package:arcadiaplus/src/services/config_converter.dart';
import 'package:arcadiaplus/src/services/native_core_service.dart';
import 'package:arcadiaplus/src/services/rule_provider_service.dart';
import 'package:arcadiaplus/src/utils/app_memory_policy.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

/// Release-mode workload with the dashboard, GeoIP and native bridge loaded.
/// Uses a temporary provider and loopback sockets. Exit status includes the
/// lifetime RSS high-water mark, so a spike between snapshots still fails.
Future<void> main() async {
  if (!kReleaseMode) throw StateError('Build this target in release mode');
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final isolated = Platform.isWindows
      ? support.path.endsWith('ArcadiaPlusMemoryBenchmark')
      : Platform.isAndroid && support.path.contains('.memorybench/');
  if (!isolated) {
    throw StateError('Build the workload with isolated app storage');
  }
  app.main();
  final directory = await Directory.systemTemp.createTemp('arcadia-memory-');
  final providers = RuleProviderService(storageRoot: () async => directory);
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) => request.response.close());
  var initialized = false;
  Map<String, int>? measurement;
  try {
    if (!await NativeCoreService.instance.initialize()) {
      throw StateError('Native core initialization failed');
    }
    final startup = Stopwatch()..start();
    while (app.navigatorKey.currentState == null) {
      if (startup.elapsed > const Duration(seconds: 15)) {
        throw StateError('Dashboard startup timed out');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await WidgetsBinding.instance.endOfFrame;
    if (await core.isProxyRunning()) throw StateError('Engine already active');
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final port = reservation.port;
    await reservation.close();
    final startupPeak = ProcessInfo.maxRss;
    final input = File('${directory.path}/domains.yaml');
    final file = input.openSync(mode: FileMode.write);
    const count = int.fromEnvironment('DOMAIN_COUNT', defaultValue: 150000);
    try {
      file.writeStringSync('payload:\n');
      for (var i = 0; i < count; i += 1000) {
        final block = StringBuffer();
        for (var j = i; j < i + 1000 && j < count; j++) {
          block.writeln("  - 'node-$j.budget.test'");
        }
        file.writeStringSync(block.toString());
      }
      file.writeStringSync("  - '+.localhost'\n");
    } finally {
      file.closeSync();
    }
    final profile = jsonEncode({
      'mixed-port': port,
      'dns': {'enable': false},
      'rule-providers': {
        'local': {'type': 'file', 'behavior': 'domain', 'path': input.path},
      },
      'rules': ['RULE-SET,local,DIRECT', 'MATCH,REJECT'],
    });
    final report = await providers.prepare('benchmark', profile);
    final providerPeak = ProcessInfo.maxRss;
    if (report.entryCount != count + 1) throw StateError('Incomplete provider');
    final config = ConfigConverter.convertClashYamlToJson(
      profile,
      ruleProviderPaths: report.paths,
      requireCompleteRules: true,
    );
    await core.initializeCorduit(configJson: config);
    initialized = true;
    await core.startCorduit();
    client.findProxy = (_) => 'PROXY 127.0.0.1:$port';
    final url = Uri.parse('http://localhost:${server.port}/');
    await Future.wait(
      List.generate(16, (_) async {
        final response = await (await client.getUrl(url)).close();
        await response.drain<void>();
        if (response.statusCode != HttpStatus.ok) {
          throw StateError('Proxy returned ${response.statusCode}');
        }
      }),
    ).timeout(const Duration(seconds: 30));
    final rules = await core.getRulesWindow(offset: 0, limit: 2, refresh: true);
    if (rules.rules.first.matchedCount != BigInt.from(16)) {
      throw StateError(
        'Unexpected provider hits: ${rules.rules.first.matchedCount}',
      );
    }
    final live = await core.getSystemInfo();
    await core.stopCorduit();
    initialized = false;
    measurement = {
      'entries': report.entryCount,
      'requests': 16,
      'ruleHits': rules.rules.first.matchedCount.toInt(),
      'dashboardPeakBytes': startupPeak,
      'providerPeakBytes': providerPeak,
      'coreHeapBytes': live.coreHeapBytes.toInt(),
    };
  } catch (error, stack) {
    debugPrint(
      'ARCADIA_MEMORY failed at peak ${ProcessInfo.maxRss} bytes: $error\n$stack',
    );
  } finally {
    if (initialized) await core.stopCorduit();
    client.close(force: true);
    await server.close(force: true);
    providers.dispose();
    await directory.delete(recursive: true);
  }
  if (measurement == null) exit(1);
  final peak = ProcessInfo.maxRss;
  measurement['peakRssBytes'] = peak;
  measurement['budgetBytes'] = AppMemoryPolicy.processBudgetBytes;
  debugPrint('ARCADIA_MEMORY ${jsonEncode(measurement)}');
  exit(peak > 0 && peak <= AppMemoryPolicy.processBudgetBytes ? 0 : 1);
}
