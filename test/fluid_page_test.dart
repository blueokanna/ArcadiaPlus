import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/widgets/fluid_page.dart';
import 'package:arcadiaplus/src/utils/app_lifecycle.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';

void main() {
  testWidgets('nested sections share one finite page timeline', (tester) async {
    Animation<double>? parent;
    Animation<double>? nested;
    await tester.pumpWidget(
      MaterialApp(
        home: FluidPage(
          child: Builder(
            builder: (context) {
              parent = FluidPage.animationOf(context);
              return FluidPage(
                child: Builder(
                  builder: (context) {
                    nested = FluidPage.animationOf(context);
                    return const Text('nested');
                  },
                ),
              );
            },
          ),
        ),
      ),
    );
    expect(identical(parent, nested), isTrue);
    expect(tester.binding.transientCallbackCount, 1);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });
  testWidgets(
    'short empty-state labels stay centered across the full viewport',
    (tester) async {
      tester.view.physicalSize = const Size(380, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: FluidEmptyState(
                    icon: Icons.power_off,
                    title: 'Stopped',
                    message: 'Start service',
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tester.getCenter(find.text('Stopped')).dx, closeTo(190, .1));
      expect(
        tester.getCenter(find.byIcon(Icons.power_off)).dx,
        closeTo(190, .1),
      );
    },
  );

  testWidgets('visible rows share the page clock without delayed tickers', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FluidPage(
          child: Column(
            children: [
              for (var i = 0; i < 8; i++)
                StaggeredListItem(index: i, child: Text('row $i')),
            ],
          ),
        ),
      ),
    );
    final rows = tester
        .widgetList<FadeTransition>(
          find.descendant(
            of: find.byType(StaggeredListItem),
            matching: find.byType(FadeTransition),
          ),
        )
        .toList();
    expect(rows.length, 8);
    await tester.pump(const Duration(milliseconds: 160));
    expect(rows.first.opacity.value, greaterThan(rows.last.opacity.value));
    // Eight phased reveals still use the page's single active ticker.
    expect(tester.binding.transientCallbackCount, 1);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });
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
