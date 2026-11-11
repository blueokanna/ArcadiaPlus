import 'package:arcadiaplus/src/widgets/expressive_shape.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app(double value, {bool reduced = false, bool enabled = true}) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: TickerMode(
            enabled: enabled,
            child: Center(
              child: AnimatedExpressiveShape(
                progress: value,
                child: const SizedBox.square(
                  dimension: 64,
                  child: ColoredBox(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      );
  double progress(WidgetTester tester) => tester
      .widget<ExpressiveShape>(find.byType(ExpressiveShape))
      .progress
      .value;

  testWidgets(
    'shape reverses from its current position and leaves no idle ticker',
    (tester) async {
      await tester.pumpWidget(app(0));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(app(1));
      await tester.pump(const Duration(milliseconds: 60));
      final before = progress(tester);
      expect(before, greaterThan(0));
      expect(before, lessThan(1));
      await tester.pumpWidget(app(0));
      expect(progress(tester), closeTo(before, .0001));
      await tester.pumpAndSettle();
      expect(progress(tester), closeTo(0, .001));
      expect(tester.binding.transientCallbackCount, 0);
    },
  );

  testWidgets('reduced motion and hidden routes settle the shape immediately', (
    tester,
  ) async {
    await tester.pumpWidget(app(0));
    await tester.pumpWidget(app(1));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(app(1, reduced: true));
    expect(progress(tester), 1);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(app(0, enabled: false));
    expect(progress(tester), 0);
    expect(tester.binding.transientCallbackCount, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });

  testWidgets('every catalogue morph has finite, nonempty geometry', (
    tester,
  ) async {
    for (final pair in ExpressiveShapePair.values) {
      for (final value in [0.0, .5, 1.0]) {
        await tester.pumpWidget(
          MaterialApp(
            home: ExpressiveShape(
              pair: pair,
              progress: AlwaysStoppedAnimation(value),
              child: const SizedBox.square(dimension: 64),
            ),
          ),
        );
        final clipper = tester.widget<ClipPath>(find.byType(ClipPath)).clipper!;
        final bounds = clipper.getClip(const Size(64, 64)).getBounds();
        expect(bounds.isFinite, true);
        expect(bounds.isEmpty, false);
      }
    }
  });
}
