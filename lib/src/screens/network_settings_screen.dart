import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:go_router/go_router.dart';
import 'package:arcadia_plus/src/providers/network_settings_provider.dart';
import 'package:arcadia_plus/src/l10n/app_localizations.dart';
import 'package:arcadia_plus/src/widgets/adaptive_list_tile.dart';
import 'package:arcadia_plus/src/rust/api.dart' as api;

class NetworkSettingsScreen extends StatefulWidget {
  const NetworkSettingsScreen({super.key});

  @override
  State<NetworkSettingsScreen> createState() => _NetworkSettingsScreenState();
}

class _NetworkSettingsScreenState extends State<NetworkSettingsScreen> {
  final TextEditingController _bypassDomainsController =
      TextEditingController();
  bool _isLoadingUwp = false;

  @override
  void dispose() {
    _bypassDomainsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);

    return Consumer<NetworkSettingsProvider>(
      builder: (context, networkSettings, child) {
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n?.network ?? 'Network'),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => context.go('/settings'),
              tooltip: l10n?.back ?? 'Back',
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 系统代理
              if (networkSettings.supportsSystemProxy) ...[
                _buildSectionHeader(
                  context,
                  l10n?.systemProxy ?? 'System Proxy',
                  Icons.public_outlined,
                ),
                Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainerLow,
                  child: Column(
                    children: [
                      AdaptiveListTile(
                        title: Text(l10n?.systemProxy ?? 'System Proxy'),
                        subtitle: Text(
                          networkSettings.systemProxy
                              ? (l10n?.enabled ?? 'Enabled')
                              : (l10n?.disabled ?? 'Disabled'),
                        ),
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: networkSettings.systemProxy
                                ? colorScheme.primaryContainer
                                : colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.public,
                            color: networkSettings.systemProxy
                                ? colorScheme.primary
                                : colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: Switch.adaptive(
                          value: networkSettings.systemProxy,
                          onChanged: (value) => _applySystemProxy(value),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // 绕过域名
              _buildSectionHeader(
                context,
                l10n?.bypassDomains ?? 'Bypass Domains',
                Icons.block_outlined,
              ),
              Card(
                elevation: 0,
                color: colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.primaryContainer.withValues(
                            alpha: 0.3,
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 20,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                l10n?.bypassDomainsDesc ??
                                    'Only effective when system proxy is enabled',
                                style: textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _bypassDomainsController,
                              decoration: InputDecoration(
                                hintText: 'example.com',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 12,
                                ),
                                filled: true,
                                fillColor: colorScheme.surfaceContainerHighest,
                              ),
                              onSubmitted: (value) {
                                if (value.trim().isNotEmpty) {
                                  networkSettings.addBypassDomain(value.trim());
                                  _bypassDomainsController.clear();
                                }
                              },
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton.icon(
                            onPressed: () {
                              final domain = _bypassDomainsController.text
                                  .trim();
                              if (domain.isNotEmpty) {
                                networkSettings.addBypassDomain(domain);
                                _bypassDomainsController.clear();
                              }
                            },
                            icon: const Icon(Icons.add),
                            label: Text(l10n?.add ?? 'Add'),
                          ),
                        ],
                      ),
                      if (networkSettings.bypassDomains.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: networkSettings.bypassDomains.map((domain) {
                            return Chip(
                              label: Text(domain),
                              deleteIcon: const Icon(Icons.close, size: 18),
                              onDeleted: () =>
                                  networkSettings.removeBypassDomain(domain),
                              backgroundColor: colorScheme.surfaceContainerHigh,
                              side: BorderSide.none,
                            );
                          }).toList(),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // TUN 模式
              _buildSectionHeader(
                context,
                l10n?.tunMode ?? 'TUN Mode',
                Icons.router_outlined,
              ),
              Card(
                elevation: 0,
                color: colorScheme.surfaceContainerLow,
                child: Column(
                  children: [
                    AdaptiveListTile(
                      title: Text(l10n?.tunMode ?? 'TUN Mode'),
                      subtitle: Text(
                        l10n?.tunModeDesc ??
                            'Requires administrator privileges',
                      ),
                      leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: networkSettings.tunEnabled
                              ? colorScheme.primaryContainer
                              : colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          Icons.router,
                          color: networkSettings.tunEnabled
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                      trailing: Switch.adaptive(
                        value: networkSettings.tunEnabled,
                        onChanged: (value) => _applyTun(value),
                      ),
                    ),
                  ],
                ),
              ),

              // Windows UWP 回环
              if (Platform.isWindows) ...[
                const SizedBox(height: 24),
                _buildSectionHeader(
                  context,
                  l10n?.uwpLoopback ?? 'UWP Loopback',
                  Icons.window_outlined,
                ),
                Card(
                  elevation: 0,
                  color: colorScheme.surfaceContainerLow,
                  child: Column(
                    children: [
                      AdaptiveListTile(
                        title: Text(
                          l10n?.uwpLoopbackTool ?? 'UWP Loopback Tool',
                        ),
                        subtitle: Text(
                          l10n?.uwpLoopbackToolDesc ??
                              'Open AppContainer loopback exemption tool',
                        ),
                        leading: Icon(
                          Icons.build_outlined,
                          color: colorScheme.primary,
                        ),
                        trailing: _isLoadingUwp
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.open_in_new),
                        onTap: _isLoadingUwp
                            ? null
                            : () => _openUwpLoopbackTool(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _buildUwpInfoCard(context),
              ],

              const SizedBox(height: 32),
            ],
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

  Widget _buildUwpInfoCard(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final l10n = AppLocalizations.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colorScheme.tertiary.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.tertiary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.info_outline,
                  color: colorScheme.tertiary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                l10n?.aboutUwpLoopback ?? 'About UWP Loopback',
                style: textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colorScheme.tertiary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            l10n?.uwpLoopbackExplain ??
                'Windows UWP apps (like Microsoft Edge, Microsoft Store) cannot access local proxy by default. After enabling UWP loopback exemption, these apps can access network through local proxy.',
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 12),
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
                  size: 18,
                  color: colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n?.requiresAdmin ??
                        'This operation requires administrator privileges',
                    style: textTheme.bodySmall?.copyWith(
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
    );
  }

  /// Applies the system proxy and reports a rejection instead of leaving the
  /// switch in a state the platform never reached.
  Future<void> _applySystemProxy(bool value) async {
    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    final l10n = AppLocalizations.of(context);
    final provider = context.read<NetworkSettingsProvider>();

    try {
      await provider.setSystemProxy(value);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${l10n?.systemProxy ?? 'System Proxy'}: '
            '${l10n?.failed ?? 'Failed'} ($e)',
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: errorColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }
  }

  Future<void> _applyTun(bool value) async {
    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    final l10n = AppLocalizations.of(context);
    final provider = context.read<NetworkSettingsProvider>();

    try {
      await provider.setTunEnabled(value);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('${l10n?.tunMode ?? 'TUN Mode'}: $e'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: errorColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }
  }

  Future<void> _openUwpLoopbackTool(BuildContext context) async {
    setState(() => _isLoadingUwp = true);
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    final l10n = AppLocalizations.of(context);

    try {
      final result = await api.openUwpLoopbackUtility();
      if (mounted) {
        if (result) {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(l10n?.uwpToolOpened ?? 'UWP loopback tool opened'),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          );
        } else {
          scaffoldMessenger.showSnackBar(
            SnackBar(
              content: Text(
                l10n?.uwpToolFailed ??
                    'Failed to open UWP loopback tool, please try running as administrator',
              ),
              behavior: SnackBarBehavior.floating,
              backgroundColor: errorColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text('${l10n?.error ?? 'Error'}: $e'),
            behavior: SnackBarBehavior.floating,
            backgroundColor: errorColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingUwp = false);
      }
    }
  }
}
