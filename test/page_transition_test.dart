import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:arcadiaplus/src/utils/navigation.dart';
import 'package:arcadiaplus/src/utils/page_transitions.dart';

/// A miniature of the app's router: one shell, destination routes that replace
/// each other, and a sub-page that is pushed from them.
GoRouter _testRouter() {
  return GoRouter(
    initialLocation: '/home',
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(body: child),
        routes: [
          GoRoute(
            path: '/home',
            pageBuilder: (context, state) => buildAppPage(
              state,
              const Text('HOME'),
              transition: AppPageTransition.destination,
            ),
          ),
          GoRoute(
            path: '/proxies',
            pageBuilder: (context, state) => buildAppPage(
              state,
              const Text('PROXIES'),
              transition: AppPageTransition.destination,
            ),
          ),
          GoRoute(
            path: '/settings',
            pageBuilder: (context, state) => buildAppPage(
              state,
              const Text('SETTINGS'),
              transition: AppPageTransition.destination,
            ),
          ),
          GoRoute(
            path: '/rules',
            pageBuilder: (context, state) => buildAppPage(
              state,
              const Text('RULES'),
              transition: AppPageTransition.hierarchical,
            ),
          ),
        ],
      ),
    ],
  );
}

void main() {
  testWidgets('a pushed page slides over the page below, which stays put', (
    tester,
  ) async {
    final router = _testRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    router.push('/rules');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // Mid-flight both pages are on screen: the incoming page travels over
    // the page below instead of replacing it, and it travels (the slide is
    // not already at rest).
    expect(find.text('RULES'), findsOneWidget);
    expect(find.text('HOME'), findsOneWidget);
    final slide = tester.widget<SlideTransition>(
      find
          .ancestor(
            of: find.text('RULES'),
            matching: find.byType(SlideTransition),
          )
          .first,
    );
    expect(slide.position.value.dx, greaterThan(0));

    await tester.pumpAndSettle();
    expect(find.text('RULES'), findsOneWidget);
    expect(router.canPop(), isTrue);
  });

  testWidgets('the system back gesture returns to the page that was below', (
    tester,
  ) async {
    final router = _testRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    router.push('/rules');
    await tester.pumpAndSettle();
    expect(find.text('RULES'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);

    final handled = await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(handled, isTrue);
    expect(find.text('RULES'), findsNothing);
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('the back affordance pops a pushed page', (tester) async {
    final router = _testRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    router.push('/rules');
    await tester.pumpAndSettle();

    popOrGoSettings(tester.element(find.text('RULES')));
    await tester.pumpAndSettle();

    expect(find.text('RULES'), findsNothing);
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('the back affordance jumps to Settings when nothing was pushed', (
    tester,
  ) async {
    final router = _testRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    popOrGoSettings(tester.element(find.text('HOME')));
    await tester.pumpAndSettle();

    expect(find.text('SETTINGS'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);
  });

  testWidgets('a destination settles in from above full size', (tester) async {
    final router = _testRouter();
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));

    router.go('/proxies');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Never below 1.0: a scaled-down page would expose the backdrop around
    // its edges, which is the one thing this motion exists to avoid.
    final scale = tester.widget<ScaleTransition>(
      find
          .ancestor(
            of: find.text('PROXIES'),
            matching: find.byType(ScaleTransition),
          )
          .first,
    );
    expect(scale.scale.value, greaterThanOrEqualTo(1.0));

    await tester.pumpAndSettle();
    expect(find.text('PROXIES'), findsOneWidget);
    expect(find.text('HOME'), findsNothing);
    expect(router.canPop(), isFalse);
  });
}
