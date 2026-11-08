import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';

void main() {
  Widget entrance({bool reduced = false, int index = 3, bool visible = true}) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: TickerMode(
            enabled: visible,
            child: StaggeredListItem(
              index: index,
              child: const Text('connection'),
            ),
          ),
        ),
      );

  double opacity(WidgetTester tester) => tester
      .widget<FadeTransition>(
        find.descendant(
          of: find.byType(StaggeredListItem),
          matching: find.byType(FadeTransition),
        ),
      )
      .opacity
      .value;

  testWidgets('deep list rows are immediately readable without a ticker', (
    tester,
  ) async {
    await tester.pumpWidget(entrance(index: 1000));
    expect(opacity(tester), 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('hidden routes cancel a queued entrance without resuming it', (
    tester,
  ) async {
    await tester.pumpWidget(entrance());
    expect(opacity(tester), 0);
    await tester.pumpWidget(entrance(visible: false));
    await tester.pump(const Duration(seconds: 1));
    expect(opacity(tester), 1);
    await tester.pumpWidget(entrance());
    expect(opacity(tester), 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets(
    'reduced motion reveals rows immediately and cancels queued entrance',
    (tester) async {
      await tester.pumpWidget(entrance());
      expect(opacity(tester), 0);
      await tester.pumpWidget(entrance(reduced: true));
      expect(opacity(tester), 1);
      await tester.pump(const Duration(seconds: 1));
      expect(opacity(tester), 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(entrance(reduced: true));
      expect(opacity(tester), 1);
    },
  );

  testWidgets('disposing a queued row cancels its timer', (tester) async {
    await tester.pumpWidget(entrance());
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.binding.transientCallbackCount, 0);
    // The test binding also rejects any pending timer at teardown.
  });

  test('state change curve never overshoots decoration tween bounds', () {
    const selected = BoxDecoration(
      boxShadow: [
        BoxShadow(
          color: Color(0x33000000),
          blurRadius: 12,
          offset: Offset(0, 4),
        ),
      ],
    );
    const unselected = BoxDecoration();

    for (var frame = 0; frame <= 240; frame++) {
      final progress = frame / 240;
      final curvedProgress = AnimationUtils.stateChangeCurve.transform(
        progress,
      );

      expect(curvedProgress, inInclusiveRange(0.0, 1.0));
      final decoration = BoxDecoration.lerp(
        selected,
        unselected,
        curvedProgress,
      );
      for (final shadow in decoration?.boxShadow ?? const <BoxShadow>[]) {
        expect(shadow.blurRadius, greaterThanOrEqualTo(0.0));
      }
    }
  });
}
