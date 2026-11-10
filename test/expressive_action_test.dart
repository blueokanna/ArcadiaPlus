import 'dart:ui' show SemanticsAction;

import 'package:arcadiaplus/src/widgets/expressive_action.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// Run unchanged against both SDK profiles: behavior belongs to the app's
// control contract, not to either Material library's internal widget tree.
void main() {
  Widget app({VoidCallback? onPressed, bool selected = false}) => MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(
      body: Center(
        child: ExpressiveAction(
          onPressed: onPressed,
          selected: selected,
          child: const Text('Connect'),
        ),
      ),
    ),
  );

  testWidgets('action is accessible and activates once per tap', (
    tester,
  ) async {
    var presses = 0;
    await tester.pumpWidget(app(onPressed: () => presses++));
    expect(
      tester.getSemantics(find.text('Connect')),
      matchesSemantics(
        label: 'Connect',
        isButton: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    final size = tester.getSize(find.byType(ExpressiveAction));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(56));
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(presses, 1);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('disabled action cannot activate', (tester) async {
    await tester.pumpWidget(app(selected: true));
    final node = tester.getSemantics(find.text('Connect'));
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isFalse);
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard activation works after selection changes', (
    tester,
  ) async {
    var presses = 0;
    await tester.pumpWidget(app(onPressed: () => presses++));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(onPressed: () => presses++, selected: true));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(presses, 1);
    expect(tester.takeException(), isNull);
  });
}
