import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/providers/proxies_provider.dart';
import 'package:arcadiaplus/src/screens/proxies_screen.dart';
import 'package:arcadiaplus/src/theme/app_theme.dart';
import 'package:arcadiaplus/src/widgets/proxy_node_tile.dart';

import 'support/proxy_engine_fake.dart';

class PreviewProvider extends ProxiesProvider {
  PreviewProvider({required FakeEngine engine}) : super(engine: engine);
  @override
  Future<void> loadFromActiveProfile() async {}
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Roboto',
    )..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets('native keyboard activation and node semantics', (tester) async {
    var taps = 0;
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.createTheme(AppTheme.defaultTheme, Brightness.light),
        home: Scaffold(
          body: ProxyNodeTile(
            name: 'Tokyo',
            subtitle: 'SOCKS5',
            selected: true,
            onPressed: () => taps++,
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byType(FilledButton))
          .getSemanticsData()
          .hasAction(ui.SemanticsAction.tap),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
  for (final width in [320.0, 430.0, 800.0, 1200.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final brightness in [Brightness.light, Brightness.dark]) {
        testWidgets('node page $width text $scale $brightness', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 1000);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final engine = FakeEngine();
          final provider = PreviewProvider(engine: engine)
            ..loadFromYaml('''
proxies:
  - {name: Tokyo / Primary, type: socks5, server: 127.0.0.1, port: 1080}
  - {name: Singapore / Backup, type: trojan, server: 127.0.0.1, port: 443}
proxy-groups:
  - name: Route
    type: select
    proxies: [Tokyo / Primary, Singapore / Backup, DIRECT, REJECT]
  - name: Automatic
    type: url-test
    proxies: [Tokyo / Primary, Singapore / Backup]
''');
          final boundary = GlobalKey();
          await tester.pumpWidget(
            ChangeNotifierProvider<ProxiesProvider>.value(
              value: provider,
              child: MaterialApp(
                theme: AppTheme.createTheme(AppTheme.defaultTheme, brightness),
                locale: const Locale('en'),
                supportedLocales: const [Locale('en')],
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  GlobalMaterialLocalizations.delegate,
                  GlobalWidgetsLocalizations.delegate,
                  GlobalCupertinoLocalizations.delegate,
                ],
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(scale)),
                  child: child!,
                ),
                home: RepaintBoundary(
                  key: boundary,
                  child: const ProxiesScreen(),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.byType(ChoiceChip), findsNWidgets(3));
          final semantics = tester.ensureSemantics();
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(textContrastGuideline));
          semantics.dispose();
          if (const bool.fromEnvironment('CAPTURE_UI') && scale == 1) {
            await tester.runAsync(() async {
              final render =
                  boundary.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await render.toImage();
              final bytes = (await image.toByteData(
                format: ui.ImageByteFormat.png,
              ))!;
              final file = File(
                '.dart_tool/ui-previews/nodes-$width-${brightness.name}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.pumpWidget(const SizedBox());
          provider.dispose();
          engine.dispose();
        });
      }
    }
  }
}
