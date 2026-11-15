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
Future<void> pumpScreen(
  WidgetTester tester,
  Widget child, {
  double textScale = 1,
  DnsSettingsProvider? dnsProvider,
}) async {
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => dnsProvider ?? DnsSettingsProvider(),
        ),
        ChangeNotifierProvider(create: (_) => GeneralSettingsProvider()),
        ChangeNotifierProvider(create: (_) => WallpaperProvider()),
      ],
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: child,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('DNS Material 3 picker fits a narrow screen with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final savedModes = <String>[];
    final dns = DnsSettingsProvider(
      read: () async => DnsSettings(dnsMode: 'fake-ip'),
      write: (settings) async => savedModes.add(settings.dnsMode),
    );
    await pumpScreen(
      tester,
      const DnsSettingsScreen(),
      textScale: 2,
      dnsProvider: dns,
    );
    await tester.scrollUntilVisible(
      find.byIcon(Icons.arrow_drop_down).hitTestable(),
      200,
      maxScrolls: 50,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    expect(tester.takeException(), isNull);
    final modePicker = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownMenu<String> &&
          widget.dropdownMenuEntries.any((entry) => entry.value == 'fake-ip'),
    );
    final arrow = find
        .descendant(
          of: modePicker,
          matching: find.byIcon(Icons.arrow_drop_down),
        )
        .hitTestable();
    expect(arrow, findsOneWidget);
    await tester.tap(arrow);
    await tester.pumpAndSettle();
    // The selected value also appears in the read-only text field. Match
    // the actual menu item rather than counting both copies of its label.
    expect(
      find.widgetWithText(MenuItemButton, 'Fake-IP').hitTestable(),
      findsOneWidget,
    );
    await tester.tap(
      find.widgetWithText(MenuItemButton, 'Redir-Host').hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(dns.dnsMode, 'redir-host');
    await tester.ensureVisible(modePicker);
    await tester.pumpAndSettle();
    await tester.tap(arrow);
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(MenuItemButton, 'Fake-IP').hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(dns.dnsMode, 'fake-ip');
    expect(savedModes, ['redir-host', 'fake-ip']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the DNS screen draws every section it owns', (tester) async {
    await pumpScreen(tester, const DnsSettingsScreen());

    // The three sections this screen is responsible for. The third one starts
    // below the fold on the test viewport, so it is scrolled to rather than
    // assumed to be built: a `ListView` builds what it shows.
    expect(find.text('Basic Settings'), findsOneWidget);
    expect(find.text('DNS Behaviour'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('DNS Servers'),
      300,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
    expect(find.text('DNS Servers'), findsOneWidget);

    const defaults = DnsSettings.defaultNameservers;
    expect(defaults.length, greaterThan(2));
    await tester.scrollUntilVisible(
      find.text('${defaults.length} servers'),
      150,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .first,
    );
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
    expect(find.text('Zoom'), findsOneWidget);
    expect(find.text('Choose image'), findsOneWidget);

    // With no picture chosen, the adjustments are inert rather than absent.
    final sliders = tester.widgetList<Slider>(find.byType(Slider));
    expect(sliders, hasLength(3));
    expect(sliders.every((slider) => slider.onChanged == null), isTrue);

    expect(tester.takeException(), isNull);
  });
}
