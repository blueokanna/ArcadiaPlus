import 'package:arcadiaplus/src/widgets/adaptive_button.dart';
import 'package:arcadiaplus/src/widgets/spring_press.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  double scale(WidgetTester tester) => tester
      .widget<ScaleTransition>(
        find.descendant(
          of: find.byType(SpringPress),
          matching: find.byType(ScaleTransition),
        ),
      )
      .scale
      .value;

  for (final kind in ['filled', 'outlined', 'text']) {
    testWidgets(
      '$kind preserves native activation and cancellation with spring feedback',
      (tester) async {
        var taps = 0;
        void pressed() => taps++;
        final Widget button = switch (kind) {
          'outlined' => AdaptiveOutlinedButton(
            onPressed: pressed,
            child: const Text('Action'),
          ),
          'text' => AdaptiveTextButton(
            onPressed: pressed,
            child: const Text('Action'),
          ),
          _ => AdaptiveButton(onPressed: pressed, child: const Text('Action')),
        };
        await tester.pumpWidget(MaterialApp(home: Center(child: button)));
        final gesture = await tester.startGesture(
          tester.getCenter(find.text('Action')),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 60));
        expect(scale(tester), lessThan(1));
        await gesture.cancel();
        await tester.pumpAndSettle();
        expect(scale(tester), closeTo(1, 0.0002));
        expect(taps, 0);
        await tester.tap(find.text('Action'));
        expect(
          taps,
          1,
          reason: 'Activation must not wait for animation completion.',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'unused presses allocate no animation controller and hidden presses settle',
    (tester) async {
      Widget app({bool pressed = false, bool visible = true}) => MaterialApp(
        home: TickerMode(
          enabled: visible,
          child: SpringPress(pressed: pressed, child: const Text('Action')),
        ),
      );
      await tester.pumpWidget(app());
      expect(
        tester.widget<ScaleTransition>(find.byType(ScaleTransition)).scale,
        isA<AlwaysStoppedAnimation<double>>(),
      );
      await tester.pumpWidget(app(pressed: true));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pumpWidget(app(pressed: true, visible: false));
      expect(tester.binding.transientCallbackCount, 0);
      await tester.pumpWidget(app(visible: false));
      expect(scale(tester), 1);
      await tester.pumpWidget(app());
      expect(scale(tester), 1);
      expect(tester.binding.transientCallbackCount, 0);
    },
  );
}
