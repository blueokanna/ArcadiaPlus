import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/widgets/fluid_page.dart';
import 'package:arcadiaplus/src/utils/app_lifecycle.dart';

void main() {
  for (final reduced in [false, true]) {
    testWidgets('finite fluid entry respects reduced motion=$reduced', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(disableAnimations: reduced),
            child: const Scaffold(
              body: FluidPage(
                child: FluidEmptyState(
                  icon: Icons.power_off_rounded,
                  title: 'Stopped',
                  message: 'Start the service',
                ),
              ),
            ),
          ),
        ),
      );
      expect(
        tester.binding.transientCallbackCount,
        reduced ? 0 : greaterThan(0),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('backgrounding ends motion without resuming an idle ticker', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: FluidPage(child: Text('page'))),
    );
    AppLifecycle.instance.active.value = false;
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    AppLifecycle.instance.active.value = true;
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.transientCallbackCount, 0);
  });
}
