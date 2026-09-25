import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:arcadiaplus/src/providers/dns_settings_provider.dart';
import 'package:arcadiaplus/src/providers/general_settings_provider.dart';
import 'package:arcadiaplus/src/providers/wallpaper_provider.dart';
import 'package:arcadiaplus/src/screens/dns_settings_screen.dart';
import 'package:arcadiaplus/src/screens/wallpaper_screen.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';

/// Pumps [child] with the providers it reads.
///
/// The providers fall back to their defaults when storage has not been
/// initialised, which is what happens here: nothing in these screens may need a
/// plugin to draw.
Future<void> pumpScreen(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => DnsSettingsProvider()),
        ChangeNotifierProvider(create: (_) => GeneralSettingsProvider()),
        ChangeNotifierProvider(create: (_) => WallpaperProvider()),
      ],
      child: MaterialApp(home: child),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('the DNS screen draws every section it owns', (tester) async {
    await pumpScreen(tester, const DnsSettingsScreen());

    // The three sections this screen is responsible for. The third one starts
    // below the fold on the test viewport, so it is scrolled to rather than
    // assumed to be built: a `ListView` builds what it shows.
    expect(find.text('Basic Settings'), findsOneWidget);
    expect(find.text('DNS Behaviour'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('DNS Servers'), 300);
    expect(find.text('DNS Servers'), findsOneWidget);

    // The upstream list is what the screen exists for, and it is no longer a
    // two-entry default.
    const defaults = DnsSettings.defaultNameservers;
    expect(defaults.length, greaterThan(2));
    expect(find.text('${defaults.length} servers'), findsOneWidget);
    expect(find.text('0 servers'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('the wallpaper screen draws its preview and controls', (
    tester,
  ) async {
    await pumpScreen(tester, const WallpaperScreen());

    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Blur'), findsOneWidget);
    expect(find.text('Dim'), findsOneWidget);
    expect(find.text('Choose image'), findsOneWidget);

    // With no picture chosen, the adjustments are inert rather than absent.
    final sliders = tester.widgetList<Slider>(find.byType(Slider));
    expect(sliders, hasLength(2));
    expect(sliders.every((slider) => slider.onChanged == null), isTrue);

    expect(tester.takeException(), isNull);
  });
}
