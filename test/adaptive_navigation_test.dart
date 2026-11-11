import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:arcadiaplus/src/widgets/adaptive_scaffold.dart';

void main() {
  for (final reduced in [false, true]) {
    testWidgets(
      'navigation retargets and supports keyboard; reduced=$reduced',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final router = GoRouter(
          routes: [
            ShellRoute(
              builder: (_, _, child) => AdaptiveScaffold(body: child),
              routes: [
                for (final path in [
                  '/',
                  '/proxies',
                  '/profiles',
                  '/connections',
                  '/settings',
                ])
                  GoRoute(
                    path: path,
                    builder: (_, _) => Center(child: Text('page:$path')),
                  ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          MaterialApp.router(
            theme: ThemeData(platform: TargetPlatform.android),
            routerConfig: router,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: reduced,
                textScaler: TextScaler.linear(2),
              ),
              child: child!,
            ),
          ),
        );
        await tester.pumpAndSettle();
        Focus.of(tester.element(find.byIcon(Icons.space_dashboard_rounded)))
            .requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        await tester.pump();
        expect(find.text('page:/proxies'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tap(find.byKey(const ValueKey('nav-/settings')));
        await tester.pump();
        await tester.pump();
        expect(find.text('page:/settings'), findsOneWidget);
        if (reduced) {
          expect(
            tester
                .getCenter(find.byKey(const ValueKey('navigation-indicator')))
                .dx,
            closeTo(
              tester.getCenter(find.byKey(const ValueKey('nav-/settings'))).dx,
              0.1,
            ),
          );
        }
        await tester.pumpAndSettle();
        expect(
          tester
              .getCenter(find.byKey(const ValueKey('navigation-indicator')))
              .dx,
          closeTo(
            tester.getCenter(find.byKey(const ValueKey('nav-/settings'))).dx,
            0.1,
          ),
        );
        expect(tester.binding.transientCallbackCount, 0);
        expect(tester.takeException(), isNull);
        // The shell reserves bar space even when a routed page does not use SafeArea.
        final body = tester.getRect(
          find
              .ancestor(
                of: find.text('page:/settings'),
                matching: find.byType(Center),
              )
              .first,
        );
        final bar = tester.getRect(
          find.byKey(const ValueKey('floating-navigation')),
        );
        expect(body.bottom, lessThanOrEqualTo(bar.top));
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  for (final platform in [TargetPlatform.android, TargetPlatform.windows]) {
    for (final size in [
      const Size(390, 844),
      const Size(800, 1280),
      const Size(1280, 800),
      const Size(740, 360),
    ]) {
      testWidgets('$platform navigation routes correctly at $size', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        final router = GoRouter(
          routes: [
            ShellRoute(
              builder: (_, _, child) => AdaptiveScaffold(body: child),
              routes: [
                for (final path in [
                  '/',
                  '/proxies',
                  '/profiles',
                  '/connections',
                  '/logs',
                  '/settings',
                ])
                  GoRoute(
                    path: path,
                    builder: (_, _) => Center(child: Text('page:$path')),
                  ),
              ],
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          MaterialApp.router(
            theme: ThemeData(platform: platform),
            routerConfig: router,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Logs'),
          platform == TargetPlatform.android ? findsNothing : findsOneWidget,
        );
        final settings = find.text('Settings');
        await tester.ensureVisible(settings);
        await tester.tap(settings);
        await tester.pumpAndSettle();
        expect(find.text('page:/settings'), findsOneWidget);
        expect(tester.takeException(), isNull);
        // Rotation preserves the active destination and navigation policy.
        tester.view.physicalSize = Size(size.height, size.width);
        await tester.pumpAndSettle();
        expect(find.text('page:/settings'), findsOneWidget);
        expect(
          find.text('Logs'),
          platform == TargetPlatform.android ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
