import '../theme/app_motion.dart';
import '../widgets/expressive_shape.dart';

import 'package:arcadiaplus/src/widgets/app_bottom_sheet.dart';

import '../widgets/page_insets.dart';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/providers/profiles_provider.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';

class ProfilesScreen extends StatefulWidget {
  const ProfilesScreen({super.key});

  @override
  State<ProfilesScreen> createState() => _ProfilesScreenState();
}

class _ProfilesScreenState extends State<ProfilesScreen> {
  @override
  void initState() {
    super.initState();
    // Load profiles on init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<ProfilesProvider>().loadProfiles();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Consumer<ProfilesProvider>(
      builder: (context, profilesProvider, child) {
        return Scaffold(
          appBar: AppBar(
            title: Text(l10n?.profiles ?? 'Profiles'),
            actions: [
              if (profilesProvider.isLoading)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: l10n?.addProfile ?? 'Add Profile',
                  onPressed: () => _showAddProfileDialog(context),
                ),
            ],
          ),
          body: profilesProvider.profiles.isEmpty
              ? _buildEmptyState(context, l10n)
              : Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final columns =
                            constraints.maxWidth >= 840 &&
                                MediaQuery.textScalerOf(context).scale(14) <= 20
                            ? 2
                            : 1;
                        return ListView.builder(
                          padding: PageInsets.scroll(
                            context,
                            const EdgeInsets.fromLTRB(20, 20, 20, 96),
                          ),
                          itemCount:
                              (profilesProvider.profiles.length / columns)
                                  .ceil(),
                          itemBuilder: (context, row) => Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (
                                var column = 0;
                                column < columns;
                                column++
                              ) ...[
                                if (column > 0) const SizedBox(width: 16),
                                Expanded(
                                  child:
                                      row * columns + column <
                                          profilesProvider.profiles.length
                                      ? _buildProfileCard(
                                          context,
                                          profilesProvider.profiles[row *
                                                  columns +
                                              column],
                                          profilesProvider,
                                          l10n,
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
          floatingActionButton: Padding(
            padding: EdgeInsets.only(bottom: PageInsets.bottomOf(context)),
            child: FloatingActionButton.extended(
              onPressed: () => _showAddProfileDialog(context),
              icon: const Icon(Icons.add),
              label: Text(l10n?.addProfile ?? 'Add Profile'),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context, AppLocalizations? l10n) {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_off_outlined,
            size: 72,
            color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            l10n?.noProfiles ?? 'No profiles',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 8),
          Text(
            l10n?.addProfileHint ?? 'Tap + to add a configuration profile',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileCard(
    BuildContext context,
    ProfileConfig profile,
    ProfilesProvider provider,
    AppLocalizations? l10n,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isActive = profile.id == provider.activeProfileId;

    return Card(
      elevation: 0,
      color: isActive
          ? colorScheme.primaryContainer
          : colorScheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () async {
          final success = await provider.selectProfile(profile.id);
          if (context.mounted) {
            if (!success) {
              // Show error message
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(provider.error ?? 'Failed to select profile'),
                  backgroundColor: Theme.of(context).colorScheme.error,
                  action: SnackBarAction(
                    label: l10n?.close ?? 'Close',
                    textColor: Theme.of(context).colorScheme.onError,
                    onPressed: () {
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    },
                  ),
                ),
              );
            } else if (provider.error != null &&
                provider.error!.contains('unavailable')) {
              // Show warning message when profile selected but proxy unavailable
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(provider.error!),
                  backgroundColor: Theme.of(context).colorScheme.tertiary,
                  action: SnackBarAction(
                    label: l10n?.close ?? 'Close',
                    textColor: Theme.of(context).colorScheme.onTertiary,
                    onPressed: () {
                      ScaffoldMessenger.of(context).hideCurrentSnackBar();
                    },
                  ),
                ),
              );
            }
          }
        },
        borderRadius: BorderRadius.circular(28),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  AnimatedExpressiveShape(
                    progress: isActive ? 1 : 0,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isActive
                            ? colorScheme.primary
                            : colorScheme.surfaceContainerHighest,
                      ),
                      child: Icon(
                        _getProfileTypeIcon(profile.type),
                        color: isActive
                            ? colorScheme.onPrimary
                            : colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          profile.name,
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: isActive
                                ? colorScheme.onPrimaryContainer
                                : colorScheme.onSurface,
                          ),
                        ),
                        if (profile.lastUpdated != null)
                          Text(
                            '${l10n?.lastUpdated ?? 'Updated'}: ${_formatDate(profile.lastUpdated!)}',
                            style: textTheme.bodySmall?.copyWith(
                              color: isActive
                                  ? colorScheme.onPrimaryContainer.withValues(
                                      alpha: 0.7,
                                    )
                                  : colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(
                      Icons.more_vert,
                      color: isActive
                          ? colorScheme.onPrimaryContainer
                          : colorScheme.onSurfaceVariant,
                    ),
                    onSelected: (value) =>
                        _handleProfileAction(profile, value, provider),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'update',
                        child: ListTile(
                          leading: const Icon(Icons.refresh),
                          title: Text(l10n?.updateProfile ?? 'Update'),
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'edit',
                        child: ListTile(
                          leading: const Icon(Icons.edit),
                          title: Text(l10n?.editProfile ?? 'Edit'),
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                      const PopupMenuDivider(),
                      PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          leading: Icon(Icons.delete, color: colorScheme.error),
                          title: Text(
                            l10n?.deleteProfile ?? 'Delete',
                            style: TextStyle(color: colorScheme.error),
                          ),
                          contentPadding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              if (isActive) ...[
                const SizedBox(height: 12),
                Chip(
                  avatar: Icon(
                    Icons.check_rounded,
                    size: 18,
                    color: colorScheme.onPrimary,
                  ),
                  label: Text(l10n?.inUse ?? 'In Use'),
                  labelStyle: textTheme.labelMedium?.copyWith(
                    color: colorScheme.onPrimary,
                  ),
                  backgroundColor: colorScheme.primary,
                  side: BorderSide.none,
                ),
              ],

              // Traffic info if available
              if (profile.usedTraffic != null &&
                  profile.totalTraffic != null) ...[
                const SizedBox(height: 12),
                _buildTrafficProgress(context, profile, isActive),
              ],

              // Expiry info
              if (profile.expiresAt != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      Icons.schedule,
                      size: 14,
                      color: isActive
                          ? colorScheme.onPrimaryContainer.withValues(
                              alpha: 0.7,
                            )
                          : colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${l10n?.expiresOn ?? 'Expires'}: ${_formatDate(profile.expiresAt!)}',
                        style: textTheme.bodySmall?.copyWith(
                          color: isActive
                              ? colorScheme.onPrimaryContainer.withValues(
                                  alpha: 0.7,
                                )
                              : colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTrafficProgress(
    BuildContext context,
    ProfileConfig profile,
    bool isActive,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    final used = (profile.usedTraffic ?? 0).clamp(0, 0x7FFFFFFFFFFFFFFF);
    final total = (profile.totalTraffic ?? 0).clamp(0, 0x7FFFFFFFFFFFFFFF);
    // A missing/zero quota does not describe a percentage. Keep the measured
    // bytes visible without inventing a limit or feeding NaN to the painter.
    final progress = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            Text(
              _formatTraffic(used),
              style: textTheme.bodySmall?.copyWith(
                color: isActive
                    ? colorScheme.onPrimaryContainer
                    : colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              total > 0 ? '/ ${_formatTraffic(total)}' : '/ —',
              style: textTheme.bodySmall?.copyWith(
                color: isActive
                    ? colorScheme.onPrimaryContainer.withValues(alpha: 0.7)
                    : colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          value: progress,
          backgroundColor: isActive
              ? colorScheme.onPrimaryContainer.withValues(alpha: 0.2)
              : colorScheme.surfaceContainerHighest,
          valueColor: AlwaysStoppedAnimation<Color>(
            progress > 0.9 ? colorScheme.error : colorScheme.primary,
          ),
        ),
      ],
    );
  }

  void _showAddProfileDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) {
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                  l10n?.addProfile ?? 'Add Profile',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 24),

                // URL option
                _buildAddOption(
                  context,
                  icon: Icons.link,
                  title: l10n?.importUrl ?? 'Import from URL',
                  subtitle: l10n?.importUrlDesc ?? 'Enter subscription URL',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _showUrlInputDialog(context);
                  },
                ),
                const SizedBox(height: 12),

                // File option
                _buildAddOption(
                  context,
                  icon: Icons.folder_open,
                  title: l10n?.importFile ?? 'Import File',
                  subtitle:
                      l10n?.importFileDesc ??
                      'Select configuration file from storage',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _handleFileImport();
                  },
                ),
                const SizedBox(height: 12),

                // Clipboard option
                _buildAddOption(
                  context,
                  icon: Icons.content_paste,
                  title: l10n?.importClipboard ?? 'Import from Clipboard',
                  subtitle:
                      l10n?.importClipboardDesc ??
                      'Paste configuration from clipboard',
                  onTap: () {
                    Navigator.pop(sheetContext);
                    _handleClipboardImport();
                  },
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildAddOption(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: colorScheme.onPrimaryContainer),
        ),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  void _showUrlInputDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final urlController = TextEditingController();
    final nameController = TextEditingController();
    // Get provider reference at the beginning, before showing dialog
    final provider = context.read<ProfilesProvider>();

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          scrollable: true,
          title: Text(l10n?.importUrl ?? 'Import from URL'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: l10n?.profileName ?? 'Profile Name',
                  hintText:
                      l10n?.profileNameHint ?? 'Enter a name for this profile',
                  prefixIcon: const Icon(Icons.label),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: urlController,
                decoration: InputDecoration(
                  labelText: l10n?.subscriptionUrl ?? 'Subscription URL',
                  hintText: 'https://',
                  prefixIcon: const Icon(Icons.link),
                  border: const OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(l10n?.cancel ?? 'Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (urlController.text.isNotEmpty) {
                  final name = nameController.text.isEmpty
                      ? 'Profile ${provider.profiles.length + 1}'
                      : nameController.text;
                  final url = urlController.text;

                  Navigator.pop(dialogContext);

                  final success = await provider.addProfileFromUrl(name, url);
                  if (!mounted) return;

                  if (success) {
                    _showSnackBar('Profile added successfully');
                  } else {
                    _showSnackBar(
                      'Failed to import: ${provider.error ?? "Unknown error"}',
                    );
                  }
                }
              },
              child: Text(l10n?.import_ ?? 'Import'),
            ),
          ],
        );
      },
    );
  }

  void _handleFileImport() async {
    final l10n = AppLocalizations.of(context);
    final provider = context.read<ProfilesProvider>();

    try {
      // Use file_picker to select a file
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['yaml', 'yml', 'json', 'txt'],
      );

      if (file == null) {
        return; // User cancelled
      }

      String? content;
      final fileName = file.name;

      // file_picker 12 exposes one cross-platform reader: `readAsBytes()`.
      // The old `bytes` field only existed on web/mobile and `path` only on
      // desktop, which is how the two branches here used to drift apart.
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          content = utf8.decode(bytes);
        }
      } on FormatException {
        content = null;
      }

      if (content == null || content.isEmpty) {
        if (!mounted) return;
        _showSnackBar(l10n?.importFileDesc ?? 'Failed to read file content');
        return;
      }

      // Generate profile name from file name (remove extension)
      final profileName = fileName.replaceAll(
        RegExp(r'\.(yaml|yml|json|txt)$'),
        '',
      );

      // Add profile
      final success = await provider.addProfileFromFile(
        profileName,
        file.path ?? 'file',
        content,
      );

      if (!mounted) return;

      if (success) {
        _showSnackBar(l10n?.import_ ?? 'Profile imported successfully');
      } else {
        _showSnackBar(
          '${l10n?.failed ?? "Failed"}: ${provider.error ?? "Unknown error"}',
        );
      }
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('${l10n?.failed ?? "Failed"}: $e');
    }
  }

  void _handleClipboardImport() async {
    final l10n = AppLocalizations.of(context);
    // Get provider reference before any async operations
    final provider = context.read<ProfilesProvider>();

    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted) return;

      if (data?.text != null && data!.text!.isNotEmpty) {
        final clipboardText = data.text!.trim();

        // Generate a unique name with timestamp
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final name = 'Clipboard_$timestamp';

        // Check if it's a URL or raw config
        if (clipboardText.startsWith('http://') ||
            clipboardText.startsWith('https://')) {
          // It's a subscription URL
          final success = await provider.addProfileFromUrl(name, clipboardText);
          if (!mounted) return;

          if (success) {
            _showSnackBar(l10n?.import_ ?? 'Profile imported successfully');
          } else {
            _showSnackBar(
              '${l10n?.failed ?? "Failed"}: ${provider.error ?? "Unknown error"}',
            );
          }
        } else if (clipboardText.startsWith('vmess://') ||
            clipboardText.startsWith('vless://') ||
            clipboardText.startsWith('ss://') ||
            clipboardText.startsWith('ssr://') ||
            clipboardText.startsWith('trojan://') ||
            clipboardText.startsWith('hysteria://') ||
            clipboardText.startsWith('hysteria2://') ||
            clipboardText.startsWith('tuic://')) {
          // It's a proxy link - treat as URL for the provider to handle
          final success = await provider.addProfileFromUrl(name, clipboardText);
          if (!mounted) return;

          if (success) {
            _showSnackBar(l10n?.import_ ?? 'Profile imported successfully');
          } else {
            _showSnackBar(
              '${l10n?.failed ?? "Failed"}: ${provider.error ?? "Unknown error"}',
            );
          }
        } else {
          // Treat as raw config content (YAML/JSON)
          final success = await provider.addProfileFromFile(
            name,
            'clipboard',
            clipboardText,
          );
          if (!mounted) return;

          if (success) {
            _showSnackBar(l10n?.import_ ?? 'Profile imported successfully');
          } else {
            _showSnackBar(
              '${l10n?.failed ?? "Failed"}: ${provider.error ?? "Unknown error"}',
            );
          }
        }
      } else {
        _showSnackBar(l10n?.noData ?? 'Clipboard is empty');
      }
    } catch (e) {
      if (!mounted) return;
      _showSnackBar('${l10n?.failed ?? "Failed"}: $e');
    }
  }

  void _handleProfileAction(
    ProfileConfig profile,
    String action,
    ProfilesProvider provider,
  ) async {
    final l10n = AppLocalizations.of(context);

    switch (action) {
      case 'update':
        final success = await provider.updateProfile(profile.id);
        if (!mounted) return;
        if (!success) {
          _showSnackBar(
            'Failed to update: ${provider.error ?? "Unknown error"}',
          );
        } else if (provider.error != null) {
          // The subscription itself refreshed; the rule sets that go with it
          // did not, so say so instead of claiming a clean update.
          _showSnackBar(
            'Profile updated, rule sets unavailable: '
            '${provider.error}',
          );
        } else {
          _showSnackBar('Profile updated successfully');
        }
        break;
      case 'edit':
        _showEditProfileDialog(context, profile, provider);
        break;
      case 'delete':
        showDialog(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: Text(l10n?.deleteProfile ?? 'Delete Profile'),
              content: Text(
                l10n?.deleteProfileConfirm ??
                    'Are you sure you want to delete this profile?',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(l10n?.cancel ?? 'Cancel'),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: () async {
                    Navigator.pop(dialogContext);
                    await provider.deleteProfile(profile.id);
                    if (!mounted) return;
                    _showSnackBar('Profile deleted');
                  },
                  child: Text(l10n?.delete ?? 'Delete'),
                ),
              ],
            );
          },
        );
        break;
    }
  }

  void _showEditProfileDialog(
    BuildContext context,
    ProfileConfig profile,
    ProfilesProvider provider,
  ) {
    showAppBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _EditProfileSheet(
        profile: profile,
        provider: provider,
        onSaved: () {
          if (mounted) _showSnackBar('Profile saved');
        },
      ),
    );
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  IconData _getProfileTypeIcon(String type) {
    switch (type) {
      case 'url':
        return Icons.link;
      case 'file':
        return Icons.insert_drive_file;
      case 'qrcode':
        return Icons.qr_code;
      default:
        return Icons.description;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _formatTraffic(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var value = bytes.toDouble();
    var unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    // Always show 2 decimal places for GB and above
    if (unitIndex >= 3) {
      return '${value.toStringAsFixed(2)} ${units[unitIndex]}';
    }
    return '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unitIndex]}';
  }
}

/// Edit Profile Bottom Sheet - Material Design 3 Expressive
class _EditProfileSheet extends StatefulWidget {
  final ProfileConfig profile;
  final ProfilesProvider provider;
  final VoidCallback? onSaved;

  const _EditProfileSheet({
    required this.profile,
    required this.provider,
    this.onSaved,
  });

  @override
  State<_EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends State<_EditProfileSheet> {
  late TextEditingController _nameController;
  late TextEditingController _urlController;
  late TextEditingController _intervalController;
  late bool _autoUpdate;
  bool _isSaving = false;
  int? _configSize;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.profile.name);
    _urlController = TextEditingController(
      text: widget.profile.type == 'url' ? widget.profile.source : '',
    );
    _intervalController = TextEditingController(
      text: widget.profile.autoUpdateInterval.toString(),
    );
    _autoUpdate = widget.profile.autoUpdate;
    _loadConfigSize();
  }

  Future<void> _loadConfigSize() async {
    final size = await widget.provider.getProfileConfigSize(widget.profile.id);
    if (mounted) {
      setState(() {
        _configSize = size;
      });
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  String _formatTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inMinutes < 1) {
      return '刚刚';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes} 分钟前';
    } else if (difference.inHours < 24) {
      return '${difference.inHours} 小时前';
    } else if (difference.inDays < 30) {
      return '${difference.inDays} 天前';
    } else {
      return '${dateTime.year}-${dateTime.month.toString().padLeft(2, '0')}-${dateTime.day.toString().padLeft(2, '0')}';
    }
  }

  Future<void> _handleSave() async {
    if (_isSaving) return;
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('名称不能为空')));
      return;
    }

    setState(() => _isSaving = true);

    try {
      final interval = int.tryParse(_intervalController.text.trim());
      if (_autoUpdate &&
          (interval == null || interval <= 0 || interval > 525600)) {
        throw const FormatException('Update interval must be 1–525600 minutes');
      }

      final success = await widget.provider.editProfile(
        id: widget.profile.id,
        name: _nameController.text.trim(),
        source: widget.profile.type == 'url'
            ? _urlController.text.trim()
            : null,
        autoUpdate: _autoUpdate,
        autoUpdateInterval: interval ?? widget.profile.autoUpdateInterval,
      );

      if (!mounted) return;

      if (success) {
        widget.onSaved?.call();
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: ${widget.provider.error ?? "未知错误"}')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _handleUpdate() async {
    if (widget.profile.type != 'url') return;

    setState(() => _isSaving = true);

    try {
      final success = await widget.provider.updateProfile(widget.profile.id);
      if (!mounted) return;

      if (success) {
        await _loadConfigSize();
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('配置已更新')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('更新失败: ${widget.provider.error ?? "未知错误"}')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _openConfigEditor() async {
    final content = await widget.provider.getProfileConfigContent(
      widget.profile.id,
    );
    if (!mounted) return;
    if (content == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Configuration file was not found')),
      );
      return;
    }

    final controller = TextEditingController(text: content);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit configuration'),
        content: SizedBox(
          width: 720,
          height: MediaQuery.sizeOf(dialogContext).height * 0.6,
          child: TextField(
            controller: controller,
            expands: true,
            maxLines: null,
            minLines: null,
            textAlignVertical: TextAlignVertical.top,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.multiline,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              final success = await widget.provider.saveProfileConfigContent(
                widget.profile.id,
                controller.text,
              );
              if (!dialogContext.mounted) return;
              if (success) {
                Navigator.pop(dialogContext, true);
              } else {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  SnackBar(
                    content: Text(
                      widget.provider.error ?? 'Invalid configuration',
                    ),
                  ),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (saved == true && mounted) {
      await _loadConfigSize();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Configuration saved')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final isUrlType = widget.profile.type == 'url';
    final zh = Localizations.localeOf(context).languageCode == 'zh';

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        width: 32,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colorScheme.onSurfaceVariant.withValues(
                            alpha: 0.4,
                          ),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Header
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            zh ? '编辑配置' : 'Edit profile',
                            style: textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: MaterialLocalizations.of(context)
                              .closeButtonTooltip,
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                          style: IconButton.styleFrom(
                            backgroundColor:
                                colorScheme.surfaceContainerHighest,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),

                    // Name field
                    TextField(
                      controller: _nameController,
                      decoration: InputDecoration(
                        labelText: zh ? '名称' : 'Name',
                        hintText: zh ? '输入配置名称' : 'Profile name',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        filled: true,
                        fillColor: colorScheme.surfaceContainerLow,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // URL field (only for URL type)
                    if (isUrlType) ...[
                      TextField(
                        controller: _urlController,
                        decoration: InputDecoration(
                          labelText: 'URL',
                          hintText: 'https://',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          filled: true,
                          fillColor: colorScheme.surfaceContainerLow,
                        ),
                        keyboardType: TextInputType.url,
                        maxLines: 1,
                      ),
                      const SizedBox(height: 20),

                      // Auto update switch
                      Material(
                        color: colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: SwitchListTile(
                          title: Text(zh ? '自动更新' : 'Auto update'),
                          value: _autoUpdate,
                          onChanged: (value) {
                            setState(() => _autoUpdate = value);
                          },
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Auto update interval (only show when auto update is enabled)
                      AnimatedSize(
                        duration: AppMotion.duration(context),
                        child: _autoUpdate
                            ? Column(
                                children: [
                                  TextField(
                                    controller: _intervalController,
                                    decoration: InputDecoration(
                                      labelText: zh
                                          ? '自动更新间隔（分钟）'
                                          : 'Update interval (minutes)',
                                      hintText: '180',
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      filled: true,
                                      fillColor:
                                          colorScheme.surfaceContainerLow,
                                    ),
                                    keyboardType: TextInputType.number,
                                  ),
                                  const SizedBox(height: 20),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                    ],

                    // Config info section
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            zh ? '配置' : 'Configuration',
                            style: textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            children: [
                              if (_configSize != null) ...[
                                Text(
                                  _formatFileSize(_configSize!),
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                Text(
                                  '  ·  ',
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                              if (widget.profile.lastUpdated != null)
                                Text(
                                  _formatTimeAgo(widget.profile.lastUpdated!),
                                  style: textTheme.bodyMedium?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // Action buttons
                          Wrap(
                            children: [
                              // Edit config button
                              OutlinedButton.icon(
                                onPressed: _isSaving ? null : _openConfigEditor,
                                icon: const Icon(Icons.edit_outlined, size: 18),
                                label: Text(zh ? '编辑' : 'Edit'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 10,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),

                              // Update button (only for URL type)
                              if (isUrlType)
                                OutlinedButton.icon(
                                  onPressed: _isSaving ? null : _handleUpdate,
                                  icon: _isSaving
                                      ? SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: colorScheme.primary,
                                          ),
                                        )
                                      : const Icon(
                                          Icons.cloud_upload_outlined,
                                          size: 18,
                                        ),
                                  label: Text(zh ? '更新' : 'Update'),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 10,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),

                    const SizedBox(height: 8),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _isSaving ? null : _handleSave,
                icon: _isSaving
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colorScheme.onPrimary,
                        ),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(zh ? '保存' : 'Save'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
