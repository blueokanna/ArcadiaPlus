import 'package:arcadiaplus/src/widgets/theme_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:arcadiaplus/src/providers/app_state_provider.dart';
import 'package:arcadiaplus/src/providers/theme_provider.dart';
import 'package:arcadiaplus/src/providers/locale_provider.dart';
import 'package:arcadiaplus/src/providers/general_settings_provider.dart';
import 'package:arcadiaplus/src/providers/update_provider.dart';
import 'package:arcadiaplus/src/providers/wallpaper_provider.dart';
import 'package:arcadiaplus/src/widgets/adaptive_list_tile.dart';
import 'package:arcadiaplus/src/widgets/license_viewer.dart';
import 'package:arcadiaplus/src/utils/platform_utils.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:package_info_plus/package_info_plus.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _packageInfo = info;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);

    return Consumer2<AppStateProvider, ThemeProvider>(
      builder: (context, appState, themeProvider, child) {
        return Scaffold(
          appBar: AppBar(
            title: Text(
              l10n?.settings ?? 'Settings',
              style: textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          body: RefreshIndicator(
            onRefresh: () async => await appState.refreshStatus(),
            child: ListView(
              physics: PlatformUtils.getScrollPhysics(),
              padding: PlatformUtils.getPlatformPadding(context),
              children: [
                // 外观设置
                _buildSectionHeader(
                  context,
                  l10n?.appearance ?? 'Appearance',
                  Icons.palette_outlined,
                ),
                Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainerLow,
                  child: Column(
                    children: [
                      AdaptiveListTile(
                        title: Text(l10n?.themeMode ?? 'Theme Mode'),
                        subtitle: Text(
                          _getThemeModeText(appState.themeMode, l10n),
                        ),
                        leading: Icon(
                          appState.themeMode == ThemeMode.dark
                              ? Icons.dark_mode_outlined
                              : appState.themeMode == ThemeMode.light
                              ? Icons.light_mode_outlined
                              : Icons.brightness_auto_outlined,
                          color: colorScheme.primary,
                        ),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: DropdownButton<ThemeMode>(
                            value: appState.themeMode,
                            underline: const SizedBox.shrink(),
                            isDense: true,
                            borderRadius: BorderRadius.circular(12),
                            dropdownColor: colorScheme.surfaceContainerHigh,
                            items: [
                              DropdownMenuItem(
                                value: ThemeMode.system,
                                child: Text(l10n?.system ?? 'Follow System'),
                              ),
                              DropdownMenuItem(
                                value: ThemeMode.light,
                                child: Text(l10n?.light ?? 'Light'),
                              ),
                              DropdownMenuItem(
                                value: ThemeMode.dark,
                                child: Text(l10n?.dark ?? 'Dark'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null) appState.setThemeMode(value);
                            },
                          ),
                        ),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      AdaptiveListTile(
                        title: Text(l10n?.themeStyle ?? 'Theme Style'),
                        subtitle: Row(
                          children: [
                            Flexible(
                              child: Text(
                                themeProvider.useDynamicColors
                                    ? (l10n?.dynamicColors ?? 'DynamicColors')
                                    : themeProvider.getThemeDisplayName(
                                        themeProvider.selectedTheme,
                                      ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 10),
                            _PaletteStrip(
                              scheme: themeProvider.getThemePreviewScheme(
                                themeProvider.selectedTheme,
                                Theme.of(context).brightness,
                              ),
                              size: 12,
                            ),
                          ],
                        ),
                        leading: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: themeProvider.useDynamicColors
                                ? colorScheme.primary
                                : _getThemePreviewColor(
                                    themeProvider.selectedTheme,
                                    context,
                                  ),
                          ),
                        ),
                        trailing: themeProvider.useDynamicColors
                            ? Icon(
                                Icons.lock_outline,
                                color: colorScheme.onSurfaceVariant,
                              )
                            : const Icon(Icons.chevron_right),
                        onTap: themeProvider.useDynamicColors
                            ? null
                            : () => showThemePicker(context, themeProvider),
                        enabled: !themeProvider.useDynamicColors,
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      if (WallpaperProvider.isSupported) ...[
                        Consumer<WallpaperProvider>(
                          builder: (context, wallpaper, child) {
                            return AdaptiveListTile(
                              title: Text(l10n?.wallpaper ?? 'Wallpaper'),
                              subtitle: Text(
                                wallpaper.isVisible
                                    ? (l10n?.enabled ?? 'Enabled')
                                    : (l10n?.disabled ?? 'Disabled'),
                              ),
                              leading: Icon(
                                Icons.wallpaper_outlined,
                                color: colorScheme.primary,
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => context.push('/wallpaper'),
                            );
                          },
                        ),
                        const Divider(height: 1, indent: 16, endIndent: 16),
                      ],
                      AdaptiveListTile(
                        title: Text(l10n?.dynamicColors ?? 'Dynamic Colors'),
                        subtitle: Text(
                          themeProvider.dynamicColorAvailable == false
                              ? (l10n?.dynamicColorUnavailable ??
                                    'Dynamic colours are not available on this '
                                        'platform')
                              : (l10n?.useSystemAccentColors ??
                                    'Use system accent colors'),
                        ),
                        leading: Icon(
                          Icons.color_lens_outlined,
                          color: colorScheme.primary,
                        ),
                        trailing: Switch.adaptive(
                          value: themeProvider.useDynamicColors,
                          onChanged:
                              themeProvider.dynamicColorAvailable == false
                              ? null
                              : (value) =>
                                    themeProvider.setUseDynamicColors(value),
                        ),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      Consumer<LocaleProvider>(
                        builder: (context, localeProvider, child) {
                          return AdaptiveListTile(
                            title: Text(l10n?.language ?? 'Language'),
                            subtitle: Text(
                              localeProvider.getLocaleName(
                                localeProvider.currentLocale,
                                systemDefaultName:
                                    l10n?.systemDefault ?? 'System Default',
                              ),
                            ),
                            leading: Icon(
                              Icons.language_outlined,
                              color: colorScheme.primary,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () =>
                                _showLanguageSelector(context, localeProvider),
                          );
                        },
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      Consumer<GeneralSettingsProvider>(
                        builder: (context, generalSettings, child) {
                          return AdaptiveListTile(
                            title: Text(
                              l10n?.hapticFeedback ?? 'Haptic Feedback',
                            ),
                            subtitle: Text(
                              l10n?.hapticFeedbackDesc ??
                                  'Vibrate on interaction',
                            ),
                            leading: Icon(
                              Icons.vibration_outlined,
                              color: colorScheme.primary,
                            ),
                            trailing: Switch.adaptive(
                              value: generalSettings.hapticFeedbackEnabled,
                              onChanged: (value) {
                                generalSettings.setHapticFeedbackEnabled(value);
                                AnimationUtils.setHapticEnabled(value);
                                if (value) {
                                  AnimationUtils.mediumHaptic();
                                }
                              },
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                _buildSectionHeader(
                  context,
                  l10n?.configuration ?? 'Configuration',
                  Icons.tune_outlined,
                ),
                Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainerLow,
                  child: Column(
                    children: [
                      AdaptiveListTile(
                        title: Text(l10n?.basicConfig ?? 'Basic Configuration'),
                        subtitle: Text(
                          l10n?.basicConfigDesc ??
                              'Port, mode, logs, and other basic settings',
                        ),
                        leading: Icon(
                          Icons.settings_outlined,
                          color: colorScheme.primary,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push('/basic-config'),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      AdaptiveListTile(
                        title: Text(
                          l10n?.advancedConfig ?? 'Advanced Configuration',
                        ),
                        subtitle: Text(
                          l10n?.advancedConfigDesc ?? 'TCP, speed test, processes, and other advanced settings',
                        ),
                        leading: Icon(
                          Icons.build_outlined,
                          color: colorScheme.primary,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push('/advanced-config'),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      AdaptiveListTile(
                        title: Text(l10n?.dnsSettings ?? 'DNS Settings'),
                        subtitle: Text(
                          l10n?.dnsSettingsDesc ??
                              'DNS servers, Fake-IP, Fallback, etc.',
                        ),
                        leading: Icon(
                          Icons.dns_outlined,
                          color: colorScheme.primary,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push('/dns-settings'),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                if (PlatformUtils.isDesktop) ...[
                  _buildSectionHeader(
                    context,
                    l10n?.network ?? 'Network',
                    Icons.wifi_outlined,
                  ),
                  Card(
                    elevation: 0,
                    color: colorScheme.surfaceContainerLow,
                    child: Column(
                      children: [
                        AdaptiveListTile(
                          title: Text(
                            l10n?.networkSettings ?? 'Network Settings',
                          ),
                          subtitle: Text(
                            l10n?.systemProxyTunUwp ??
                                'System proxy, TUN, UWP loopback',
                          ),
                          leading: Icon(
                            Icons.settings_ethernet_outlined,
                            color: colorScheme.primary,
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => context.push('/network-settings'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],

                // 服务设置
                _buildSectionHeader(
                  context,
                  l10n?.service ?? 'Service',
                  Icons.miscellaneous_services_outlined,
                ),
                Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainerLow,
                  child: Column(
                    children: [
                      AdaptiveListTile(
                        title: Text(l10n?.serviceStatus ?? 'Service Status'),
                        subtitle: Text(
                          appState.isServiceRunning
                              ? (l10n?.running ?? 'Running')
                              : (l10n?.stopped ?? 'Stopped'),
                        ),
                        leading: Icon(
                          appState.isServiceRunning
                              ? Icons.play_circle_outline
                              : Icons.stop_circle_outlined,
                          color: appState.isServiceRunning
                              ? colorScheme.primary
                              : colorScheme.error,
                        ),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      if (PlatformUtils.isDesktop) ...[
                        AdaptiveListTile(
                          title: Text(
                            l10n?.autoSystemProxy ?? 'Automatic system proxy',
                          ),
                          subtitle: Text(
                            l10n?.autoSystemProxyDesc ??
                                'Enable the system proxy when the service '
                                    'starts',
                          ),
                          leading: Icon(
                            Icons.settings_system_daydream_outlined,
                            color: colorScheme.primary,
                          ),
                          trailing: Switch.adaptive(
                            value: appState.autoSystemProxy,
                            onChanged: (value) =>
                                appState.setAutoSystemProxy(value),
                          ),
                        ),
                        const Divider(height: 1, indent: 16, endIndent: 16),
                      ],

                      AdaptiveListTile(
                        title: Text(l10n?.viewLogs ?? 'View Logs'),
                        subtitle: Text(
                          l10n?.viewLogsDesc ??
                              'View runtime logs and debug information',
                        ),
                        leading: Icon(
                          Icons.article_outlined,
                          color: colorScheme.primary,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push('/logs'),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                _buildSectionHeader(
                  context,
                  l10n?.about ?? 'About',
                  Icons.info_outline,
                ),
                Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainerLow,
                  child: Column(
                    children: [
                      AdaptiveListTile(
                        title: Text(l10n?.version ?? 'Version'),
                        subtitle: Text(
                          _packageInfo?.version ?? appState.version,
                        ),
                        leading: Icon(
                          Icons.tag_outlined,
                          color: colorScheme.primary,
                        ),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      Consumer<UpdateProvider>(
                        builder: (context, updater, child) {
                          final update = updater.availableUpdate;
                          final updateVersion = update?.version ?? '';
                          final busy =
                              updater.state == UpdateState.checking ||
                              updater.state == UpdateState.downloading ||
                              updater.state == UpdateState.installing;
                          final subtitle = switch (updater.state) {
                            UpdateState.available =>
                              l10n?.updateAvailable(updateVersion) ??
                                  'ArcadiaPlus $updateVersion is available',
                            UpdateState.downloading =>
                              l10n?.downloadingProgress(
                                    (updater.downloadProgress * 100).round(),
                                  ) ??
                                  'Downloading ${(updater.downloadProgress * 100).round()}%',
                            UpdateState.installing =>
                              l10n?.openingInstaller ?? 'Opening installer',
                            UpdateState.error =>
                              l10n?.updateFailed('${updater.lastError}') ??
                                  'Update failed: ${updater.lastError}',
                            _ =>
                              l10n?.stableReleaseCheckDescription ??
                                  'Check stable GitHub Releases',
                          };
                          return AdaptiveListTile(
                            title: Text(
                              l10n?.checkForUpdates ?? 'Check for updates',
                            ),
                            subtitle: Text(subtitle),
                            leading: Icon(
                              Icons.system_update_alt_rounded,
                              color: colorScheme.primary,
                            ),
                            trailing: busy
                                ? const SizedBox.square(
                                    dimension: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.chevron_right),
                            enabled: !busy,
                            onTap: busy
                                ? null
                                : update == null
                                ? () => updater.check()
                                : () => updater.downloadAndInstall(),
                          );
                        },
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      AdaptiveListTile(
                        title: Text(l10n?.buildInfo ?? 'Build Info'),
                        subtitle: Text(appState.buildInfo),
                        leading: Icon(
                          Icons.build_outlined,
                          color: colorScheme.primary,
                        ),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      AdaptiveListTile(
                        title: Text(l10n?.disclaimer ?? 'Disclaimer'),
                        subtitle: Text(
                          l10n?.disclaimerDesc ??
                              'Terms of service and legal notices',
                        ),
                        leading: Icon(
                          Icons.gavel_outlined,
                          color: colorScheme.primary,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _showDisclaimerDialog(context),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      AdaptiveListTile(
                        title: Text(
                          l10n?.aboutArcadiaPlus ?? 'About ArcadiaPlus',
                        ),
                        subtitle: Text(
                          l10n?.aboutArcadiaPlusDesc ??
                              'Learn more about this app',
                        ),
                        leading: Icon(
                          Icons.flash_on_outlined,
                          color: colorScheme.primary,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push('/about'),
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      AdaptiveListTile(
                        title: Text(l10n?.license ?? 'License'),
                        subtitle: Text(
                          l10n?.licenseName ?? 'PolyForm Perimeter 1.0.1',
                        ),
                        leading: Icon(
                          Icons.article_outlined,
                          color: colorScheme.primary,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => showBundledLicense(context),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                _buildSectionHeader(
                  context,
                  l10n?.actions ?? 'Actions',
                  Icons.bolt_outlined,
                ),
                Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainerLow,
                  child: Column(
                    children: [
                      AdaptiveListTile(
                        title: Text(l10n?.restartService ?? 'Restart Service'),
                        subtitle: Text(
                          l10n?.restartServiceDesc ??
                              'Restart the ArcadiaPlus service',
                        ),
                        leading: Icon(
                          Icons.restart_alt_outlined,
                          color: colorScheme.primary,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: appState.isServiceRunning
                            ? () => _showRestartDialog(context, appState)
                            : null,
                        enabled: appState.isServiceRunning,
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      AdaptiveListTile(
                        title: Text(l10n?.resetSettings ?? 'Reset Settings'),
                        subtitle: Text(
                          l10n?.resetSettingsDesc ??
                              'Reset all settings to their default values',
                        ),
                        leading: Icon(
                          Icons.settings_backup_restore_outlined,
                          color: colorScheme.error,
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _showResetDialog(context, appState),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSectionHeader(
    BuildContext context,
    String title,
    IconData icon,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colorScheme.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }

  String _getThemeModeText(ThemeMode mode, AppLocalizations? l10n) {
    switch (mode) {
      case ThemeMode.system:
        return l10n?.system ?? 'Follow System';
      case ThemeMode.light:
        return l10n?.light ?? 'Light';
      case ThemeMode.dark:
        return l10n?.dark ?? 'Dark';
    }
  }

  Color _getThemePreviewColor(String themeName, BuildContext context) {
    return context.read<ThemeProvider>().getThemeSeedColor(themeName);
  }

  void _showDisclaimerDialog(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.gavel_outlined, color: colorScheme.primary),
            const SizedBox(width: 12),
            Text(l10n?.disclaimer ?? 'Disclaimer'),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n?.disclaimerTitle ?? 'Terms of Use',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              Text(
                l10n?.disclaimerContent ??
                    'ArcadiaPlus is a network proxy tool, for legal use only.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.warning_amber_outlined,
                      color: colorScheme.error,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n?.disclaimerWarning ?? 'Illegal use of the proxy tool may lead to legal consequences.',
                        style: TextStyle(
                          color: colorScheme.error,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n?.understood ?? 'I Understand'),
          ),
        ],
      ),
    );
  }

  void _showRestartDialog(BuildContext context, AppStateProvider appState) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n?.restartService ?? 'Restart Service'),
        content: Text(
          l10n?.restartServiceConfirm ??
              'Restart the service? Active connections drop while it does.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n?.cancel ?? 'Cancel'),
          ),
          FilledButton(
            onPressed: () {
              appState.restartService();
              Navigator.of(context).pop();
            },
            child: Text(l10n?.restartService ?? 'Restart'),
          ),
        ],
      ),
    );
  }

  void _showResetDialog(BuildContext context, AppStateProvider appState) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n?.resetSettings ?? 'Reset Settings'),
        content: Text(
          l10n?.resetSettingsConfirm ??
              'Reset every setting to its default? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n?.cancel ?? 'Cancel'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(l10n?.resetSettingsDone ?? 'Settings reset'),
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              );
            },
            style: FilledButton.styleFrom(backgroundColor: colorScheme.error),
            child: Text(l10n?.reset ?? 'Reset'),
          ),
        ],
      ),
    );
  }

  void _showLanguageSelector(
    BuildContext context,
    LocaleProvider localeProvider,
  ) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.8,
          expand: false,
          builder: (context, scrollController) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.3,
                          ),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      l10n?.language ?? 'Language',
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 16),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        itemCount: LocaleProvider.supportedLocales.length,
                        itemBuilder: (context, index) {
                          final localeInfo =
                              LocaleProvider.supportedLocales[index];
                          final isSelected =
                              localeProvider.currentLocale == localeInfo.locale;

                          return Card(
                            elevation: 0,
                            color: isSelected
                                ? colorScheme.primaryContainer
                                : colorScheme.surfaceContainerLow,
                            margin: const EdgeInsets.only(bottom: 8),
                            child: ListTile(
                              leading: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? colorScheme.primary
                                      : colorScheme.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Center(
                                  child: Text(
                                    localeInfo.flag,
                                    style: const TextStyle(fontSize: 16),
                                  ),
                                ),
                              ),
                              title: Text(
                                localeInfo.name,
                                style: TextStyle(
                                  fontWeight: isSelected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: isSelected
                                      ? colorScheme.onPrimaryContainer
                                      : colorScheme.onSurface,
                                ),
                              ),
                              trailing: isSelected
                                  ? Icon(
                                      Icons.check_circle,
                                      color: colorScheme.primary,
                                    )
                                  : null,
                              onTap: () {
                                localeProvider.setLocale(localeInfo.locale);
                                Navigator.pop(context);
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// The primary, secondary and tertiary colours of a palette, side by side.
///
/// Three swatches rather than one: a single colour cannot tell the difference
/// between two themes that share an accent, and it is the relationship between
/// the roles that makes a Material palette look like itself.
class _PaletteStrip extends StatelessWidget {
  const _PaletteStrip({required this.scheme, required this.size});

  final ColorScheme scheme;

  /// Diameter of one swatch, in logical pixels.
  final double size;

  @override
  Widget build(BuildContext context) {
    final colors = [scheme.primary, scheme.secondary, scheme.tertiary];
    final step = size + 3;

    return SizedBox(
      width: step * (colors.length - 1) + size,
      height: size,
      child: Stack(
        children: [
          for (final (index, color) in colors.indexed)
            Positioned(
              left: index * step,
              top: 0,
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
            ),
        ],
      ),
    );
  }
}
