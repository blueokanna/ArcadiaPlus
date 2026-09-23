import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:arcadia/src/theme/app_theme.dart';
import 'package:arcadia/src/providers/app_state_provider.dart';
import 'package:arcadia/src/providers/theme_provider.dart';
import 'package:arcadia/src/providers/profiles_provider.dart';
import 'package:arcadia/src/providers/network_settings_provider.dart';
import 'package:arcadia/src/providers/locale_provider.dart';
import 'package:arcadia/src/providers/proxies_provider.dart';
import 'package:arcadia/src/providers/dns_settings_provider.dart';
import 'package:arcadia/src/providers/general_settings_provider.dart';
import 'package:arcadia/src/providers/update_provider.dart';
import 'package:arcadia/src/services/storage_service.dart';
import 'package:arcadia/src/services/native_core_service.dart';
import 'package:arcadia/src/screens/home_screen.dart';
import 'package:arcadia/src/screens/settings_screen.dart';
import 'package:arcadia/src/screens/connections_screen.dart';
import 'package:arcadia/src/screens/logs_screen.dart';
import 'package:arcadia/src/screens/network_settings_screen.dart';
import 'package:arcadia/src/screens/dns_settings_screen.dart';
import 'package:arcadia/src/screens/basic_config_screen.dart';
import 'package:arcadia/src/screens/advanced_config_screen.dart';
import 'package:arcadia/src/screens/proxies_screen.dart';
import 'package:arcadia/src/widgets/adaptive_scaffold.dart';
import 'package:arcadia/src/widgets/rust_init_error_dialog.dart';
import 'package:arcadia/src/widgets/update_prompt.dart';
import 'package:arcadia/src/utils/platform_utils.dart';
import 'package:arcadia/src/utils/device_info_utils.dart';
import 'package:arcadia/src/utils/animation_utils.dart';
import 'package:arcadia/src/utils/app_lifecycle.dart';
import 'package:arcadia/src/l10n/app_localizations.dart';
import 'package:arcadia/src/screens/profiles_screen.dart';
import 'package:go_router/go_router.dart';
import 'package:dynamic_color/dynamic_color.dart';

bool _errorDialogShown = false;

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Timers and animations consult this before spending CPU, so it has to be
  // observing before the first screen is built.
  AppLifecycle.instance.start();
  runApp(const ArcadiaBootstrap());
}

class ArcadiaBootstrap extends StatefulWidget {
  const ArcadiaBootstrap({super.key});

  @override
  State<ArcadiaBootstrap> createState() => _ArcadiaBootstrapState();
}

class _ArcadiaBootstrapState extends State<ArcadiaBootstrap> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await Future.wait<void>([
      _guarded('native core', () async {
        await NativeCoreService.instance.initialize();
      }),
      _guarded('storage', () async {
        await StorageService.instance.init();
        final settings = await StorageService.instance.getGeneralSettings();
        AnimationUtils.setHapticEnabled(settings.hapticFeedbackEnabled);
      }),
      _guarded('device info', DeviceInfoUtils.initialize),
      _guarded('platform detection', () async {
        await PlatformUtils.checkHarmonyOS().timeout(
          const Duration(seconds: 3),
          onTimeout: () => false,
        );
      }),
    ]);

    await Future.wait<void>([
      if (PlatformUtils.isDesktop)
        _guarded('desktop window', PlatformUtils.initDesktopWindow),
      if (PlatformUtils.isMobile)
        _guarded('orientation', () async {
          await SystemChrome.setPreferredOrientations(const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
          ]);
        }),
    ]);

    if (mounted) {
      setState(() => _ready = true);
    }
  }

  Future<void> _guarded(
    String component,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
      debugPrint('$component initialized');
    } catch (error, stackTrace) {
      debugPrint('Failed to initialize $component: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) {
      return const ArcadiaApp();
    }

    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: _StartupScreen(),
    );
  }
}

class _StartupScreen extends StatefulWidget {
  const _StartupScreen();

  @override
  State<_StartupScreen> createState() => _StartupScreenState();
}

class _StartupScreenState extends State<_StartupScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _scale = Tween<double>(begin: 0.96, end: 1.04).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOutCubic),
    );
    AppLifecycle.instance.active.addListener(_syncAnimation);
    _syncAnimation();
  }

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _syncAnimation();
  }

  /// The splash is normally on screen for a moment, but a slow first launch
  /// can leave it there — and an animation that keeps running off screen is
  /// work nobody asked for.
  void _syncAnimation() {
    if (!mounted) return;
    if (_reduceMotion) {
      _controller.stop();
      _controller.value = 0.5;
      return;
    }
    if (!AppLifecycle.instance.isActive) {
      _controller.stop();
      return;
    }
    if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    AppLifecycle.instance.active.removeListener(_syncAnimation);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF00143D),
      body: Center(
        child: RepaintBoundary(
          child: ScaleTransition(
            scale: _scale,
            child: SizedBox.square(
              dimension: 132,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.asset(
                    'assets/arcadia.png',
                    filterQuality: FilterQuality.medium,
                  ),
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      final position = (_controller.value * 4) - 2;
                      return ShaderMask(
                        blendMode: BlendMode.srcIn,
                        shaderCallback: (bounds) => LinearGradient(
                          begin: Alignment(position - 0.8, -1),
                          end: Alignment(position + 0.8, 1),
                          colors: const [
                            Colors.transparent,
                            Color(0x99FFFFFF),
                            Colors.transparent,
                          ],
                          stops: const [0.35, 0.5, 0.65],
                        ).createShader(bounds),
                        child: child,
                      );
                    },
                    child: Image.asset(
                      'assets/arcadia.png',
                      color: Colors.white,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ArcadiaApp extends StatefulWidget {
  const ArcadiaApp({super.key});

  @override
  State<ArcadiaApp> createState() => _ArcadiaAppState();
}

class _ArcadiaAppState extends State<ArcadiaApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _showErrorDialogIfNeeded();
    });
  }

  Future<void> _showErrorDialogIfNeeded() async {
    final nativeCore = NativeCoreService.instance;
    if (!nativeCore.isReady && !_errorDialogShown) {
      _errorDialogShown = true;
      final context = navigatorKey.currentContext;
      if (context != null) {
        await RustInitErrorDialog.show(
          context,
          errorDetails: nativeCore.lastError,
        );
        final success = await nativeCore.initialize();
        if (success) {
          if (mounted) {
            setState(() {});
          }
        } else {
          _errorDialogShown = false;
          await _showErrorDialogIfNeeded();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppStateProvider()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider(create: (_) => ProfilesProvider()),
        ChangeNotifierProvider(create: (_) => NetworkSettingsProvider()),
        ChangeNotifierProvider(create: (_) => LocaleProvider()),
        ChangeNotifierProvider(create: (_) => ProxiesProvider()),
        ChangeNotifierProvider(create: (_) => DnsSettingsProvider()),
        ChangeNotifierProvider(create: (_) => GeneralSettingsProvider()),
        ChangeNotifierProvider(create: (_) => UpdateProvider()),
      ],
      child: DynamicColorBuilder(
        builder: (lightColorScheme, darkColorScheme) {
          return Consumer2<ThemeProvider, LocaleProvider>(
            builder: (context, themeProvider, localeProvider, child) {
              final lightTheme =
                  themeProvider.useDynamicColors && lightColorScheme != null
                  ? AppTheme.createDynamicTheme(
                      lightColorScheme,
                      Brightness.light,
                    )
                  : AppTheme.createTheme(
                      themeProvider.selectedTheme,
                      Brightness.light,
                    );

              final darkTheme =
                  themeProvider.useDynamicColors && darkColorScheme != null
                  ? AppTheme.createDynamicTheme(
                      darkColorScheme,
                      Brightness.dark,
                    )
                  : AppTheme.createTheme(
                      themeProvider.selectedTheme,
                      Brightness.dark,
                    );

              // Only the theme mode is wanted from `AppStateProvider`, and a
              // `Selector` subscribes to exactly that much of it. Watching the
              // provider as a whole rebuilt this `MaterialApp` — along with
              // both `ThemeData` objects and the entire tree below it — once a
              // second, because the provider notifies on every traffic sample.
              return Selector<AppStateProvider, ThemeMode>(
                selector: (_, appState) => appState.themeMode,
                builder: (context, themeMode, child) => MaterialApp.router(
                  title: 'Arcadia',
                  debugShowCheckedModeBanner: false,
                  theme: lightTheme,
                  darkTheme: darkTheme,
                  themeMode: themeMode,
                  locale: localeProvider.currentLocale,
                  localizationsDelegates: const [
                    AppLocalizations.delegate,
                    GlobalMaterialLocalizations.delegate,
                    GlobalWidgetsLocalizations.delegate,
                    GlobalCupertinoLocalizations.delegate,
                  ],
                  supportedLocales: AppLocalizations.supportedLocales,
                  routerConfig: _router,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

final GoRouter _router = GoRouter(
  navigatorKey: navigatorKey,
  // Lets a screen learn when it stops being the visible one, so it can put its
  // polling down instead of running behind whatever is stacked above it.
  observers: [routeObserver],
  routes: [
    ShellRoute(
      builder: (context, state, child) {
        return UpdatePromptHost(child: AdaptiveScaffold(body: child));
      },
      routes: [
        GoRoute(
          path: '/',
          pageBuilder: (context, state) =>
              _buildExpressivePage(state, const HomeScreen()),
        ),
        GoRoute(
          path: '/proxies',
          pageBuilder: (context, state) =>
              _buildExpressivePage(state, const ProxiesScreen()),
        ),
        GoRoute(
          path: '/profiles',
          pageBuilder: (context, state) =>
              _buildExpressivePage(state, const ProfilesScreen()),
        ),
        GoRoute(
          path: '/connections',
          pageBuilder: (context, state) =>
              _buildExpressivePage(state, const ConnectionsScreen()),
        ),
        GoRoute(
          path: '/logs',
          pageBuilder: (context, state) =>
              _buildExpressivePage(state, const LogsScreen()),
        ),
        GoRoute(
          path: '/settings',
          pageBuilder: (context, state) =>
              _buildExpressivePage(state, const SettingsScreen()),
        ),
        GoRoute(
          path: '/network-settings',
          pageBuilder: (context, state) =>
              _buildExpressivePage(state, const NetworkSettingsScreen()),
        ),
        GoRoute(
          path: '/dns-settings',
          pageBuilder: (context, state) =>
              _buildExpressivePage(state, const DnsSettingsScreen()),
        ),
        GoRoute(
          path: '/basic-config',
          pageBuilder: (context, state) =>
              _buildExpressivePage(state, const BasicConfigScreen()),
        ),
        GoRoute(
          path: '/advanced-config',
          pageBuilder: (context, state) =>
              _buildExpressivePage(state, const AdvancedConfigScreen()),
        ),
      ],
    ),
  ],
);

CustomTransitionPage<void> _buildExpressivePage(
  GoRouterState state,
  Widget child,
) {
  return CustomTransitionPage<void>(
    key: state.pageKey,
    child: child,
    transitionDuration: AnimationUtils.pageTransitionDuration,
    reverseTransitionDuration: const Duration(milliseconds: 300),
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      if (MediaQuery.disableAnimationsOf(context)) {
        return child;
      }

      final curvedAnimation = CurvedAnimation(
        parent: animation,
        curve: AnimationUtils.curveEmphasizedDecelerate,
        reverseCurve: AnimationUtils.curveEmphasizedAccelerate,
      );

      final fadeAnimation = Tween<double>(
        begin: 0.0,
        end: 1.0,
      ).animate(curvedAnimation);

      final slideAnimation = Tween<Offset>(
        begin: const Offset(0.03, 0),
        end: Offset.zero,
      ).animate(curvedAnimation);

      final scaleAnimation = Tween<double>(
        begin: 0.96,
        end: 1.0,
      ).animate(curvedAnimation);

      return FadeTransition(
        opacity: fadeAnimation,
        child: SlideTransition(
          position: slideAnimation,
          child: ScaleTransition(scale: scaleAnimation, child: child),
        ),
      );
    },
  );
}
