import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/providers/update_provider.dart';
import 'package:arcadiaplus/src/utils/update_error_messages.dart';

class UpdatePromptHost extends StatefulWidget {
  const UpdatePromptHost({required this.child, super.key});

  final Widget child;

  @override
  State<UpdatePromptHost> createState() => _UpdatePromptHostState();
}

class _UpdatePromptHostState extends State<UpdatePromptHost> {
  String? _shownTag;

  @override
  Widget build(BuildContext context) {
    final updater = context.watch<UpdateProvider>();
    final update = updater.availableUpdate;
    if (update != null && _shownTag != update.tag) {
      _shownTag = update.tag;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showUpdateDialog(update.tag);
      });
    }
    return widget.child;
  }

  Future<void> _showUpdateDialog(String tag) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _UpdateDialog(tag: tag),
    );
  }
}

/// The one-time prompt for a release found at startup.
///
/// It stays open through the download and the install handoff and reports an
/// installer refusal in place, because the alternative — closing on the tap
/// and leaving the background work unobservable — is how an install that
/// silently failed reads as an update that cannot be installed at all.
class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.tag});

  /// The release tag this dialog was opened for, so a later check that found
  /// a different release cannot repurpose a stale dialog.
  final String tag;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _popped = false;

  @override
  Widget build(BuildContext context) {
    final updater = context.watch<UpdateProvider>();
    final l10n = AppLocalizations.of(context);
    final update = updater.availableUpdate;
    if (update == null || update.tag != widget.tag) return const SizedBox();

    final state = updater.state;
    final busy =
        state == UpdateState.downloading || state == UpdateState.installing;
    final error = updater.installError;

    if (state == UpdateState.ready && !_popped) {
      _popped = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    }

    return AlertDialog(
      icon: const Icon(Icons.system_update_alt_rounded),
      title: Text('ArcadiaPlus ${update.version}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state == UpdateState.downloading) ...[
            Text(
              l10n?.downloadingProgress(
                    (updater.downloadProgress * 100).round(),
                  ) ??
                  'Downloading',
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: updater.downloadProgress == 0
                  ? null
                  : updater.downloadProgress,
            ),
          ] else if (state == UpdateState.installing)
            Text(l10n?.openingInstaller ?? 'Opening installer')
          else if (error != null)
            Text(
              describeUpdateInstallError(l10n, error),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            )
          else
            Text(
              l10n?.publishedOn(
                    update.publishedAt.toLocal().toString().split('.').first,
                  ) ??
                  'Published',
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: Text(l10n?.cancel ?? 'Cancel'),
        ),
        if (error != null) ...[
          TextButton(
            onPressed: () => launchUrl(
              update.releasePage,
              mode: LaunchMode.externalApplication,
            ),
            child: Text(l10n?.openReleasesPage ?? 'Open the releases page'),
          ),
          // The refusal is about the package, not about the download — a
          // permission prompt that was just granted, for instance, makes the
          // same file installable, and re-downloading it costs nothing.
          FilledButton.icon(
            onPressed: updater.downloadAndInstall,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(l10n?.download ?? 'Download'),
          ),
        ] else
          FilledButton.icon(
            onPressed: busy ? null : updater.downloadAndInstall,
            icon: const Icon(Icons.download_rounded),
            label: Text(l10n?.download ?? 'Download'),
          ),
      ],
    );
  }
}
