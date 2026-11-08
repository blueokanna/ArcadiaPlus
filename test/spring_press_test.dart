import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/widgets/spring_press.dart';

void main() {
  testWidgets('reversing a press preserves position and settles at rest', (
    tester,
  ) async {
    Widget app(bool pressed) => MaterialApp(
      home: SpringPress(pressed: pressed, child: const Text('button')),
    );
    double scale() => tester
        .widget<ScaleTransition>(find.byType(ScaleTransition))
        .scale
        .value;
    await tester.pumpWidget(app(false));
    await tester.pumpWidget(app(true));
    await tester.pump(const Duration(milliseconds: 40));
    final before = scale();
    expect(before, lessThan(1));
    await tester.pumpWidget(app(false));
    expect(scale(), closeTo(before, 0.000001));
    await tester.pumpAndSettle();
    expect(scale(), closeTo(1, 0.0002));
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion disables press transforms', (tester) async {
    Widget app(bool pressed) => MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: SpringPress(pressed: pressed, child: const Text('button')),
      ),
    );
    await tester.pumpWidget(app(false));
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ScaleTransition>(find.byType(ScaleTransition)).scale.value,
      1,
    );
  });

  testWidgets(
    'motion preference changes during a press keep a coherent target',
    (tester) async {
      Widget app(bool reduced) => MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: const SpringPress(pressed: true, child: Text('button')),
        ),
      );
      double scale() => tester
          .widget<ScaleTransition>(find.byType(ScaleTransition))
          .scale
          .value;
      await tester.pumpWidget(app(false));
      expect(scale(), 0.97);
      await tester.pumpWidget(app(true));
      expect(scale(), 1);
      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      expect(scale(), closeTo(0.97, 0.0002));
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
