import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:arcadiaplus/src/utils/platform_utils.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';
import 'package:arcadiaplus/src/theme/app_motion.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';

class AppNavigationBar extends StatelessWidget {
  final ValueChanged<int>? onDestinationSelected;

  const AppNavigationBar({super.key, this.onDestinationSelected});

  bool get _isMobilePlatform {
    if (kIsWeb) return false;
    return PlatformUtils.isMobile;
  }

  bool get _showLogs => !_isMobilePlatform;

  int _getCurrentIndex(BuildContext context) {
    final path = GoRouterState.of(context).uri.path;
    final location = path == '/' ? '/' : '/${path.split('/')[1]}';
    if (_showLogs) {
      switch (location) {
        case '/':
          return 0;
        case '/proxies':
          return 1;
        case '/profiles':
          return 2;
        case '/connections':
          return 3;
        case '/logs':
          return 4;
        case '/settings':
          return 5;
        default:
          return 0;
      }
    } else {
      switch (location) {
        case '/':
          return 0;
        case '/proxies':
          return 1;
        case '/profiles':
          return 2;
        case '/connections':
          return 3;
        case '/settings':
          return 4;
        default:
          return 0;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final currentIndex = _getCurrentIndex(context);
    final l10n = AppLocalizations.of(context);

    if (PlatformUtils.shouldUseSideNavigation(context)) {
      return _buildNavigationRail(context, colorScheme, currentIndex, l10n);
    }

    return _buildBottomNavigationBar(context, colorScheme, currentIndex, l10n);
  }

  Widget _buildNavigationRail(
    BuildContext context,
    ColorScheme colorScheme,
    int currentIndex,
    AppLocalizations? l10n,
  ) {
    return NavigationRail(
      selectedIndex: currentIndex,
      onDestinationSelected: (index) {
        AnimationUtils.selectionHaptic();
        onDestinationSelected?.call(index);
        _navigateToScreen(context, index);
      },
      labelType: NavigationRailLabelType.all,
      backgroundColor: colorScheme.surface,
      indicatorColor: colorScheme.secondaryContainer,
      selectedIconTheme: IconThemeData(
        color: colorScheme.onSecondaryContainer,
        size: 24,
      ),
      unselectedIconTheme: IconThemeData(
        color: colorScheme.onSurfaceVariant,
        size: 24,
      ),
      selectedLabelTextStyle: TextStyle(
        color: colorScheme.onSurface,
        fontWeight: FontWeight.w500,
        fontSize: 12,
      ),
      unselectedLabelTextStyle: TextStyle(
        color: colorScheme.onSurfaceVariant,
        fontWeight: FontWeight.w500,
        fontSize: 12,
      ),
      useIndicator: true,
      indicatorShape: const StadiumBorder(),
      minWidth: 80,
      destinations: [
        NavigationRailDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home),
          label: Text(l10n?.home ?? 'Home'),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.public_outlined),
          selectedIcon: const Icon(Icons.public),
          label: Text(l10n?.proxies ?? 'Proxies'),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.folder_outlined),
          selectedIcon: const Icon(Icons.folder),
          label: Text(l10n?.profiles ?? 'Profiles'),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.link_outlined),
          selectedIcon: const Icon(Icons.link),
          label: Text(l10n?.connections ?? 'Connections'),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.article_outlined),
          selectedIcon: const Icon(Icons.article),
          label: Text(l10n?.logs ?? 'Logs'),
        ),
        NavigationRailDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          label: Text(l10n?.settings ?? 'Settings'),
        ),
      ],
    );
  }

  Widget _buildBottomNavigationBar(
    BuildContext context,
    ColorScheme colorScheme,
    int currentIndex,
    AppLocalizations? l10n,
  ) {
    return NavigationBar(
      selectedIndex: currentIndex,
      onDestinationSelected: (index) {
        AnimationUtils.selectionHaptic();
        onDestinationSelected?.call(index);
        _navigateToScreen(context, index);
      },
      backgroundColor: colorScheme.surface,
      indicatorColor: colorScheme.secondaryContainer,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      height: 80,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      animationDuration: AppMotion.duration(context),
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.home_outlined),
          selectedIcon: const Icon(Icons.home),
          label: l10n?.home ?? 'Home',
        ),
        NavigationDestination(
          icon: const Icon(Icons.public_outlined),
          selectedIcon: const Icon(Icons.public),
          label: l10n?.proxies ?? 'Proxies',
        ),
        NavigationDestination(
          icon: const Icon(Icons.folder_outlined),
          selectedIcon: const Icon(Icons.folder),
          label: l10n?.profiles ?? 'Profiles',
        ),
        NavigationDestination(
          icon: const Icon(Icons.link_outlined),
          selectedIcon: const Icon(Icons.link),
          label: l10n?.connectionsShort ?? 'Conns',
        ),
        NavigationDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          label: l10n?.settings ?? 'Settings',
        ),
      ],
    );
  }

  void _navigateToScreen(BuildContext context, int index) {
    if (_showLogs) {
      switch (index) {
        case 0:
          context.go('/');
          break;
        case 1:
          context.go('/proxies');
          break;
        case 2:
          context.go('/profiles');
          break;
        case 3:
          context.go('/connections');
          break;
        case 4:
          context.go('/logs');
          break;
        case 5:
          context.go('/settings');
          break;
      }
    } else {
      switch (index) {
        case 0:
          context.go('/');
          break;
        case 1:
          context.go('/proxies');
          break;
        case 2:
          context.go('/profiles');
          break;
        case 3:
          context.go('/connections');
          break;
        case 4:
          context.go('/settings');
          break;
      }
    }
  }
}
