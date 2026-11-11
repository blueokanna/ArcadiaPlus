import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:arcadiaplus/src/utils/app_lifecycle.dart';
import 'package:arcadiaplus/src/widgets/app_motion_scope.dart';
import 'package:arcadiaplus/src/widgets/expressive_status_shape.dart';
import 'package:arcadiaplus/src/widgets/spring_press.dart';

void main() {
  testWidgets(
    'shared lifecycle gate settles shape and press without idle frames',
    (tester) async {
      final running = ValueNotifier(false);
      var builds = 0;
      final content = Builder(
        builder: (_) {
          builds++;
          return const SizedBox(
            width: 64,
            height: 64,
            child: ColoredBox(color: Colors.blue),
          );
        },
      );
      addTearDown(() {
        running.dispose();
        AppLifecycle.instance.active.value = true;
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => AppMotionScope(child: child!),
          home: ValueListenableBuilder<bool>(
            valueListenable: running,
            child: content,
            builder: (_, value, child) => Center(
              child: SpringPress(
                pressed: value,
                child: ExpressiveStatusShape(running: value, child: child!),
              ),
            ),
          ),
        ),
      );
      running.value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.binding.transientCallbackCount, greaterThan(0));
      final afterChange = builds;
      await tester.pump(const Duration(milliseconds: 30));
      expect(
        builds,
        afterChange,
        reason: 'animation must not rebuild its static content',
      );
      AppLifecycle.instance.active.value = false;
      await tester.pump();
      await tester.pump();
      expect(tester.binding.transientCallbackCount, 0);
      AppLifecycle.instance.active.value = true;
      await tester.pumpAndSettle();
      expect(tester.binding.transientCallbackCount, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
