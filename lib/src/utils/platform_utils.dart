import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:veloguard/src/utils/responsive_utils.dart';

class PlatformUtils {
  static bool? _isHarmonyOS;
  static bool get isHarmonyOS {
    if (_isHarmonyOS != null) return _isHarmonyOS!;

    if (kIsWeb) {
      _isHarmonyOS = false;
      return false;
    }

    try {
      final os = Platform.operatingSystem.toLowerCase();
      if (os == 'ohos' || os == 'harmonyos') {
        _isHarmonyOS = true;
        return true;
      }
    } catch (e) {
      // 忽略错误
    }

    _isHarmonyOS = false;
    return false;
  }

  static Future<bool> checkHarmonyOS() async {
    if (_isHarmonyOS != null) return _isHarmonyOS!;

    if (kIsWeb) {
      _isHarmonyOS = false;
      return false;
    }

    try {
      final os = Platform.operatingSystem.toLowerCase();
      if (os == 'ohos' || os == 'harmonyos') {
        _isHarmonyOS = true;
        return true;
      }
    } catch (e) {
      debugPrint('Failed to detect HarmonyOS: $e');
    }

    if (Platform.isAndroid) {
      try {
        const channel = MethodChannel('com.veloguard/proxy');
        final deviceInfo =
            await channel
                    .invokeMethod('getDeviceInfo')
                    .timeout(const Duration(seconds: 3), onTimeout: () => null)
                as Map?;
        if (deviceInfo != null) {
          final brand = (deviceInfo['brand'] as String?)?.toUpperCase() ?? '';
          final manufacturer =
              (deviceInfo['manufacturer'] as String?)?.toUpperCase() ?? '';
          if (brand == 'HUAWEI' ||
              brand == 'HONOR' ||
              manufacturer == 'HUAWEI' ||
              manufacturer == 'HONOR') {
            final display =
                (deviceInfo['display'] as String?)?.toLowerCase() ?? '';
            if (display.contains('harmonyos') || display.contains('hmos')) {
              _isHarmonyOS = true;
              return true;
            }
          }
        }
      } catch (e) {
        debugPrint('Failed to check HarmonyOS: $e');
      }
    }

    _isHarmonyOS = false;
    return false;
  }

  static bool get isDesktop {
    return !kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
  }

  static bool get isMobile {
    if (kIsWeb) return false;
    return Platform.isAndroid || Platform.isIOS || isHarmonyOS;
  }

  static bool get isWindows {
    return !kIsWeb && Platform.isWindows;
  }

  static bool get isAndroid {
    return !kIsWeb && Platform.isAndroid;
  }

  static bool get isIOS {
    return !kIsWeb && Platform.isIOS;
  }

  static bool get isLinux {
    return !kIsWeb && Platform.isLinux;
  }

  static bool get isMacOS {
    return !kIsWeb && Platform.isMacOS;
  }

  /// 检测是否为 OHOS 平台（HarmonyOS NEXT）
  static bool get isOHOS {
    if (kIsWeb) return false;
    try {
      return Platform.operatingSystem.toLowerCase() == 'ohos';
    } catch (e) {
      return false;
    }
  }

  static Future<void> initDesktopWindow() async {
    if (!isDesktop) return;

    await windowManager.ensureInitialized();

    const windowOptions = WindowOptions(
      size: Size(1200, 800),
      minimumSize: Size(600, 600),
      center: true,
      title: 'VeloGuard',
      titleBarStyle: TitleBarStyle.normal,
    );

    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }

  static EdgeInsets getPlatformPadding(BuildContext context) {
    return ResponsiveUtils.getResponsivePadding(context);
  }

  static double getAppBarHeight([BuildContext? context]) {
    if (context != null) {
      return ResponsiveUtils.getAppBarHeight(context);
    }
    if (isDesktop) {
      return 64;
    } else {
      return kToolbarHeight;
    }
  }

  static double getCardElevation() {
    if (isDesktop) {
      return 2;
    } else {
      return 0;
    }
  }

  static BorderRadius getBorderRadius([BuildContext? context]) {
    if (context != null) {
      return ResponsiveUtils.getCardBorderRadius(context);
    }
    if (isDesktop) {
      return BorderRadius.circular(8);
    } else {
      return BorderRadius.circular(12);
    }
  }

  // Get platform-specific icon size
  static double getIconSize(BuildContext context, {bool large = false}) {
    return ResponsiveUtils.getIconSize(context, large: large);
  }

  // Get platform-specific text scale factor
  static double getTextScaleFactor(BuildContext context) {
    return ResponsiveUtils.getFontScaleFactor(context);
  }

  // Check if running on Windows ARM64
  static bool get isWindowsArm64 {
    return isWindows && Platform.version.contains('ARM64');
  }

  // Get platform-specific file extension for executables
  static String getExecutableExtension() {
    if (isWindows) {
      return '.exe';
    } else {
      return '';
    }
  }

  // Get platform-specific configuration directory
  static String getConfigDirectory() {
    if (isWindows) {
      return '${Platform.environment['APPDATA']}\\VeloGuard';
    } else if (isLinux || isMacOS) {
      return '${Platform.environment['HOME']}/.config/veloguard';
    } else if (isAndroid || isHarmonyOS) {
      return '/data/data/com.blueokanna.veloguard/files';
    } else {
      return Directory.current.path;
    }
  }

  // Get platform-specific log directory
  static String getLogDirectory() {
    if (isWindows) {
      return '${Platform.environment['LOCALAPPDATA']}\\VeloGuard\\logs';
    } else if (isLinux || isMacOS) {
      return '${Platform.environment['HOME']}/.local/share/veloguard/logs';
    } else if (isAndroid || isHarmonyOS) {
      return '/data/data/com.blueokanna.veloguard/cache/logs';
    } else {
      return Directory.current.path;
    }
  }

  static bool shouldUseBottomNavigation([BuildContext? context]) {
    if (context != null) {
      return ResponsiveUtils.shouldShowBottomNav(context);
    }
    return isMobile;
  }

  static bool shouldUseSideNavigation([BuildContext? context]) {
    if (context != null) {
      return ResponsiveUtils.shouldShowSideNav(context);
    }
    return isDesktop;
  }

  // Platform-specific scroll behavior
  static ScrollPhysics getScrollPhysics([BuildContext? context]) {
    if (context != null) {
      return ResponsiveUtils.getScrollPhysics(context);
    }
    if (isDesktop) {
      return const ClampingScrollPhysics();
    } else {
      return const BouncingScrollPhysics();
    }
  }

  static double getDialogWidth(BuildContext context) {
    return ResponsiveUtils.getDialogMaxWidth(context);
  }

  static double? getDialogHeight(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    if (isDesktop) {
      return screenHeight * 0.6;
    } else {
      return null;
    }
  }

  static int getGridCrossAxisCount(BuildContext context) {
    return ResponsiveUtils.getGridColumnCount(context);
  }

  static double getListItemHeight([BuildContext? context]) {
    if (context != null) {
      return ResponsiveUtils.getListItemHeight(context);
    }
    if (isDesktop) {
      return 56;
    } else {
      return 48;
    }
  }

  static FloatingActionButtonLocation getFabLocation() {
    return FloatingActionButtonLocation.endFloat;
  }

  // Platform-specific animation duration
  static Duration getAnimationDuration() {
    if (isDesktop) {
      return const Duration(milliseconds: 200);
    } else {
      return const Duration(milliseconds: 300);
    }
  }

  // Platform-specific haptic feedback
  static void performHapticFeedback() {
    if (isMobile) {
      HapticFeedback.lightImpact();
    }
  }

  // Platform-specific context menu behavior
  static bool shouldShowContextMenu() {
    return isDesktop;
  }

  // Platform-specific tooltip behavior
  static bool shouldShowTooltips() {
    return isDesktop;
  }

  // Platform-specific focus behavior
  static bool get autoFocusEnabled {
    return isDesktop;
  }

  // Platform-specific gesture settings
  static bool get enableSwipeGestures {
    return isMobile;
  }

  static bool get enableDragDrop {
    return isDesktop;
  }

  // Platform-specific keyboard shortcuts
  static Map<ShortcutActivator, Intent> getKeyboardShortcuts(
    BuildContext context,
  ) {
    if (!isDesktop) return {};

    return {
      const SingleActivator(LogicalKeyboardKey.keyR, control: true):
          const RefreshIntent(),
      const SingleActivator(LogicalKeyboardKey.keyQ, control: true):
          const QuitIntent(),
      const SingleActivator(LogicalKeyboardKey.f5): const RefreshIntent(),
    };
  }
}

// Custom intents for keyboard shortcuts
class RefreshIntent extends Intent {
  const RefreshIntent();
}

class QuitIntent extends Intent {
  const QuitIntent();
}
