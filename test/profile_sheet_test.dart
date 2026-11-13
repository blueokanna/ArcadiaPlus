import 'package:arcadiaplus/src/providers/profiles_provider.dart';
import 'package:arcadiaplus/src/screens/profiles_screen.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:arcadiaplus/src/widgets/adaptive_scaffold.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:arcadiaplus/src/theme/app_theme.dart';

import 'support/capture_ui.dart';
import 'support/test_fonts.dart';

class _Profiles extends ChangeNotifier implements ProfilesProvider {
  @override
  final profiles = [
    ProfileConfig(
      id: 'test',
      name: 'Test',
      type: 'url',
      source: 'https://example.invalid',
      autoUpdate: true,
    ),
  ];
  int saved = 0;
  @override
  String get activeProfileId => 'test';
  @override
  bool get isLoading => false;
  @override
  Future<void> loadProfiles() async {}
  @override
  Future<int?> getProfileConfigSize(String id) async => 400000;
  @override
  Future<bool> editProfile({
    required String id,
    String? name,
    String? source,
    bool? autoUpdate,
    int? autoUpdateInterval,
  }) async {
    saved++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(loadAppFonts);
  for (final keyboard in [0.0, 300.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'save stays tappable above navigation and keyboard $keyboard / $scale',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(380, 812);
          tester.view.viewPadding = const FakeViewPadding(bottom: 34);
          tester.view.padding = const FakeViewPadding(bottom: 34);
          addTearDown(tester.view.reset);
          final profiles = _Profiles();
          addTearDown(profiles.dispose);
          final router = GoRouter(
            initialLocation: '/profiles',
            routes: [
              ShellRoute(
                builder: (_, _, child) => AdaptiveScaffold(body: child),
                routes: [
                  GoRoute(
                    path: '/profiles',
                    builder: (_, _) => const ProfilesScreen(),
                  ),
                ],
              ),
            ],
          );
          addTearDown(router.dispose);
          final capture = GlobalKey();
          await tester.pumpWidget(
            ChangeNotifierProvider<ProfilesProvider>.value(
              value: profiles,
              child: MaterialApp.router(
                theme: AppTheme.createTheme(
                  AppTheme.defaultTheme,
                  Brightness.light,
                ),
                routerConfig: router,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: RepaintBoundary(key: capture, child: child!),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byIcon(Icons.more_vert));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Edit'));
          await tester.pumpAndSettle();
          if (keyboard > 0) {
            await tester.tap(find.byType(TextField).first);
            tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
            tester.view.padding = const FakeViewPadding();
            await tester.pumpAndSettle();
          }
          final save = find.widgetWithText(FilledButton, 'Save');
          expect(save.hitTestable(), findsOneWidget);
          expect(
            tester.getRect(save).bottom,
            lessThanOrEqualTo(812 - (keyboard > 0 ? keyboard : 34)),
          );
          await captureTestUi(
            tester,
            capture,
            'profile-sheet-$keyboard-$scale',
          );
          await tester.tap(save);
          await tester.pumpAndSettle();
          expect(profiles.saved, 1);
          expect(find.byType(BottomSheet), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }
}
