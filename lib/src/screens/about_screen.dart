import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:arcadiaplus/src/providers/app_state_provider.dart';
import 'package:arcadiaplus/src/services/config_converter.dart';
import 'package:arcadiaplus/src/services/update_service.dart';
import 'package:arcadiaplus/src/utils/responsive_utils.dart';
import 'package:arcadiaplus/src/widgets/license_viewer.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';

/// What this build is, described only from what it can be asked.
///
/// Nothing on this screen is written down twice: the application version comes
/// from the installed package, the engine version and build target from the
/// running core, the runtime and operating system from the platform itself,
/// the protocol list from the converter's own mapping table, and the licence
/// text from the file that ships with the app. A page that quotes hard-coded
/// facts is a page that starts lying at the next release.
class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  PackageInfo? _packageInfo;

  @override
  void initState() {
    super.initState();
    _loadPackageInfo();
  }

  Future<void> _loadPackageInfo() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _packageInfo = info);
    } catch (e) {
      debugPrint('Failed to read package info: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);
    // Narrow subscriptions on purpose: this provider notifies on every traffic
    // sample, and none of those move a version string.
    final engineVersion = context.select<AppStateProvider, String>(
      (appState) => appState.version,
    );
    final buildInfo = context.select<AppStateProvider, String>(
      (appState) => appState.buildInfo,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n?.aboutArcadiaPlus ?? 'About ArcadiaPlus'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/settings'),
          tooltip: l10n?.back ?? 'Back',
        ),
      ),
      body: ListView(
        padding: ResponsiveUtils.getResponsivePadding(context),
        children: [
          _buildHeader(context, colorScheme, textTheme, l10n),
          SizedBox(height: ResponsiveUtils.getSpacing(context) * 3),

          Text(
            l10n?.aboutDescription ?? '',
            style: textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
          SizedBox(height: ResponsiveUtils.getSpacing(context) * 3),

          _sectionHeader(
            context,
            l10n?.features ?? 'Features',
            Icons.auto_awesome_outlined,
          ),
          _card(
            context,
            children: [
              for (final feature in _features(l10n))
                _featureRow(context, feature),
            ],
          ),
          SizedBox(height: ResponsiveUtils.getSpacing(context) * 3),

          _sectionHeader(
            context,
            l10n?.supportedProtocols ?? 'Supported Protocols',
            Icons.swap_horiz_outlined,
          ),
          _card(
            context,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    // Straight from the converter's mapping table, so this
                    // list cannot claim a protocol the engine would drop.
                    for (final protocol in ConfigConverter.supportedProtocols)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Text(
                          protocol,
                          style: textTheme.labelMedium?.copyWith(
                            color: colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: ResponsiveUtils.getSpacing(context) * 3),

          _sectionHeader(
            context,
            l10n?.aboutRuntimeInfo ?? 'Runtime',
            Icons.memory_outlined,
          ),
          _card(
            context,
            children: [
              for (final fact in _runtimeFacts(
                l10n,
                engineVersion: engineVersion,
                buildInfo: buildInfo,
              ))
                _factRow(context, fact),
            ],
          ),
          SizedBox(height: ResponsiveUtils.getSpacing(context) * 3),

          _sectionHeader(
            context,
            l10n?.license ?? 'License',
            Icons.gavel_outlined,
          ),
          _card(
            context,
            children: [
              _factRow(context, (
                icon: Icons.description_outlined,
                label: l10n?.license ?? 'License',
                value: l10n?.licenseName ?? 'PolyForm Perimeter 1.0.1',
              )),
              _factRow(context, (
                icon: Icons.copyright_outlined,
                label: l10n?.aboutCopyrightHolder ?? 'Copyright',
                // The notice the bundled licence requires, quoted as it is
                // written there.
                value: '© 2026 blueokanna and HyphenTeam',
              )),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.info_outline,
                        size: 20,
                        color: colorScheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          l10n?.aboutLicenseNotice ?? '',
                          style: textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => showBundledLicense(context),
                    icon: const Icon(Icons.article_outlined),
                    label: Text(
                      l10n?.aboutViewLicense ?? 'Read the full licence',
                    ),
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: ResponsiveUtils.getSpacing(context) * 3),

          _sectionHeader(
            context,
            l10n?.aboutLinks ?? 'Links',
            Icons.link_outlined,
          ),
          _card(
            context,
            children: [
              _linkRow(
                context,
                icon: Icons.code_outlined,
                title: l10n?.aboutRepository ?? 'Source code',
                subtitle: UpdateService.repositorySlug,
                url: UpdateService.repositoryUrl,
              ),
              _linkRow(
                context,
                icon: Icons.new_releases_outlined,
                title: l10n?.aboutReleases ?? 'Releases',
                subtitle: UpdateService.releasesUrl,
                url: UpdateService.releasesUrl,
              ),
              _linkRow(
                context,
                icon: Icons.bug_report_outlined,
                title: l10n?.aboutIssues ?? 'Issue tracker',
                subtitle: UpdateService.issuesUrl,
                url: UpdateService.issuesUrl,
              ),
            ],
          ),

          SizedBox(height: ResponsiveUtils.getSpacing(context) * 3),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- sections

  Widget _buildHeader(
    BuildContext context,
    ColorScheme colorScheme,
    TextTheme textTheme,
    AppLocalizations? l10n,
  ) {
    final package = _packageInfo;
    final version = package == null
        ? '—'
        : '${package.version}'
              '${package.buildNumber.isEmpty ? '' : ' (build ${package.buildNumber})'}';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(
          ResponsiveUtils.getBorderRadius(context),
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.primaryContainer,
            colorScheme.primaryContainer.withValues(alpha: 0.6),
          ],
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Image.asset(
              'assets/arcadiaplus.png',
              width: 44,
              height: 44,
              filterQuality: FilterQuality.medium,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ArcadiaPlus',
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  version,
                  style: textTheme.titleSmall?.copyWith(
                    color: colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n?.aboutTagline ?? '',
                  style: textTheme.bodySmall?.copyWith(
                    color: colorScheme.onPrimaryContainer.withValues(
                      alpha: 0.8,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The feature list, each entry paired with the icon that reads best for it.
  List<({IconData icon, String text})> _features(AppLocalizations? l10n) => [
    (
      icon: Icons.speed_outlined,
      text: l10n?.featureSpeed ?? 'Rust proxy core: multi-protocol forwarding, connection tracking and live traffic accounting',
    ),
    (
      icon: Icons.rule_outlined,
      text: l10n?.featureRules ?? 'Rule, global and direct routing modes; switching never restarts the tunnel',
    ),
    (
      icon: Icons.vpn_lock_outlined,
      text:
          l10n?.aboutFeatureTun ??
          'Two ways to take over traffic: the platform proxy and a TUN adapter',
    ),
    (
      icon: Icons.cloud_download_outlined,
      text: l10n?.aboutFeatureSubscription ?? 'Clash subscriptions: YAML conversion, local rule-set cache and scheduled refresh',
    ),
    (
      icon: Icons.dns_outlined,
      text: l10n?.featureDns ?? 'Built-in DNS: configurable upstreams, fake-IP and an optional local recursive resolver',
    ),
    (
      icon: Icons.devices_outlined,
      text:
          l10n?.featurePlatform ??
          'Windows, macOS, Linux, Android and HarmonyOS from one code base',
    ),
    (
      icon: Icons.palette_outlined,
      text:
          l10n?.featureTheme ??
          'Material 3, dynamic colour and eleven interface languages',
    ),
    (
      icon: Icons.security_outlined,
      text: l10n?.featureSecurity ?? 'Subscriptions, rule sets and updates are fetched straight from their source over TLS',
    ),
  ];

  /// What the app and the machine under it actually are.
  List<({IconData icon, String label, String value})> _runtimeFacts(
    AppLocalizations? l10n, {
    required String engineVersion,
    required String buildInfo,
  }) {
    final package = _packageInfo;
    return [
      (
        icon: Icons.tag_outlined,
        label: l10n?.version ?? 'Version',
        value: package == null
            ? '—'
            : '${package.version}+${package.buildNumber}',
      ),
      (
        icon: Icons.apps_outlined,
        label: l10n?.aboutPackageId ?? 'Application ID',
        value: package?.packageName ?? '—',
      ),
      (
        icon: Icons.hub_outlined,
        label: l10n?.aboutEngine ?? 'Proxy engine',
        value: engineVersion.isEmpty ? '—' : engineVersion,
      ),
      (
        icon: Icons.build_outlined,
        label: l10n?.aboutBuildTarget ?? 'Build target',
        value: _buildTarget(buildInfo),
      ),
      (
        icon: Icons.terminal_outlined,
        label: l10n?.aboutDartRuntime ?? 'Dart runtime',
        value: _dartRuntime(),
      ),
      (
        icon: Icons.computer_outlined,
        label: l10n?.aboutOperatingSystem ?? 'Operating system',
        value: _operatingSystem(),
      ),
    ];
  }

  // ------------------------------------------------------------------ helpers

  /// The platform corduit was built for, taken from the core's own build
  /// string. The whole string is shown when it is not in the expected shape,
  /// which is more useful than an empty row and cannot be mistaken for a fact.
  static String _buildTarget(String buildInfo) {
    if (buildInfo.isEmpty) return '—';
    final match = RegExp(
      r'^Target:\s*(.+)$',
      multiLine: true,
    ).firstMatch(buildInfo);
    return match?.group(1)?.trim() ?? buildInfo.replaceAll('\n', ' · ');
  }

  /// The Dart VM, e.g. `3.12.2 (stable) · windows_x64`. Falls back to the
  /// version string the VM reports when it does not have the shape expected
  /// here, so the row is never wrong and never empty.
  static String _dartRuntime() {
    final version = Platform.version;
    final match = RegExp(r'^(\S+)\s+\((\w+)\).*?on\s+"?([\w\-]+)"?$')
        .firstMatch(version);
    if (match == null) return version;
    return '${match.group(1)} (${match.group(2)}) · ${match.group(3)}';
  }

  static String _operatingSystem() {
    final description = Platform.operatingSystemVersion.trim();
    if (description.isEmpty) return Platform.operatingSystem;
    return description;
  }

  Widget _sectionHeader(BuildContext context, String title, IconData icon) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, left: 4),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colorScheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, {required List<Widget> children}) {
    return Card(
      elevation: 0,
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(children: children),
    );
  }

  Widget _featureRow(
    BuildContext context,
    ({IconData icon, String text}) feature,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(feature.icon, size: 20, color: colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              feature.text,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _factRow(
    BuildContext context,
    ({IconData icon, String label, String value}) fact,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(fact.icon, size: 20, color: colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            flex: 4,
            child: Text(
              fact.label,
              style: textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 6,
            child: SelectableText(
              fact.value,
              textAlign: TextAlign.end,
              style: textTheme.bodyMedium?.copyWith(height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _linkRow(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required String url,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: () => _openUrl(context, url),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colorScheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.open_in_new, size: 18, color: colorScheme.primary),
          ],
        ),
      ),
    );
  }

  Future<void> _openUrl(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    final uri = Uri.tryParse(url);
    try {
      final launched =
          uri != null &&
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) throw StateError('No application accepted $url');
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('${l10n?.failed ?? 'Failed'}: $e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: errorColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }
  }
}
