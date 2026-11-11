import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/rust/types.dart';
import 'package:arcadiaplus/src/widgets/memory_info_card.dart';
import 'package:arcadiaplus/src/theme/app_theme.dart';

import 'support/test_fonts.dart';
import 'support/capture_ui.dart';

void main() {
  setUpAll(loadAppFonts);
  for (final scale in [1.0, 2.0]) {
    testWidgets('memory details fit a narrow screen at scale $scale', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final info = SystemInfo(
        platform: 'Android',
        version: 'test',
        memoryTotal: BigInt.from(8 * 1024 * 1024 * 1024),
        memoryUsed: BigInt.from(219 * 1024 * 1024),
        cpuCores: 8,
        cpuThreads: 8,
        cpuName: 'Test CPU',
        cpuUsage: 1,
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.createTheme(AppTheme.defaultTheme, Brightness.light),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: boundary, child: child!),
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MemoryInfoCard(info: info, device: 'MatePad test fixture'),
            ),
          ),
        ),
      );
      await tester.tap(find.byType(MemoryInfoCard));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await captureTestUi(tester, boundary, 'memory-details-$scale');
      expect(find.text('219.0 MiB'), findsWidgets);
      final clear = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.cleaning_services_rounded),
      );
      expect(
        clear.onPressed,
        isNull,
        reason: 'An empty cache is not presented as reclaimable memory',
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
