import 'package:flutter/material.dart';

import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/rust/api.dart' as api;
import 'package:arcadiaplus/src/rust/types.dart' show UwpLoopbackEntry;

/// The AppContainer loopback manager.
///
/// Windows has no UI for this: the loopback exemption is stored by
/// `CheckNetIsolation.exe`, a console tool, and a Store app that cannot see
/// the local proxy has no way to say so other than "no internet". This dialog
/// is the missing screen — it lists the installed AppContainer packages,
/// shows which ones may reach the proxy, and rewrites the exemption for the
/// one that is toggled.
///
/// Every write needs an elevated token, and the engine is the one that knows
/// why a write failed; its message is shown instead of being replaced with a
/// generic failure. The list itself is readable without elevation.
class UwpLoopbackDialog extends StatefulWidget {
  const UwpLoopbackDialog({super.key});

  /// Opens the manager over [context].
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const UwpLoopbackDialog(),
    );
  }

  @override
  State<UwpLoopbackDialog> createState() => _UwpLoopbackDialogState();
}

class _UwpLoopbackDialogState extends State<UwpLoopbackDialog> {
  List<UwpLoopbackEntry>? _entries;
  String? _error;

  /// Families whose write is in flight. A second tap while one is pending
  /// would race it, so those switches are disabled instead.
  final Set<String> _busy = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _entries = null;
      _error = null;
    });
    try {
      final entries = await api.listUwpLoopback();
      if (!mounted) return;
      setState(() => _entries = entries);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _setExemption(UwpLoopbackEntry entry, bool exempt) async {
    final messenger = ScaffoldMessenger.of(context);
    final l10n = AppLocalizations.of(context);

    setState(() => _busy.add(entry.family));
    try {
      await api.setUwpLoopback(family: entry.family, exempt: exempt);
      if (!mounted) return;
      setState(() {
        _entries = [
          for (final current in _entries ?? const <UwpLoopbackEntry>[])
            if (current.family == entry.family)
              UwpLoopbackEntry(
                name: current.name,
                family: current.family,
                exempt: exempt,
              )
            else
              current,
        ];
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n?.uwpToolUpdated ?? 'UWP loopback updated'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${l10n?.uwpToolFailed ?? 'UWP loopback change failed'} ($e)',
          ),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(entry.family));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colorScheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.window_outlined, color: colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(l10n?.uwpLoopback ?? 'UWP Loopback')),
          IconButton(
            tooltip: l10n?.refresh ?? 'Refresh',
            onPressed: _entries == null && _error == null ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      content: SizedBox(width: 520, height: 420, child: _buildBody(context)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(MaterialLocalizations.of(context).closeButtonLabel),
        ),
      ],
    );
  }

  Widget _buildBody(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final colorScheme = Theme.of(context).colorScheme;

    if (_error != null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, color: colorScheme.error, size: 40),
          const SizedBox(height: 12),
          Text(
            l10n?.uwpToolFailed ?? 'UWP loopback change failed',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            label: Text(l10n?.refresh ?? 'Refresh'),
          ),
        ],
      );
    }

    final entries = _entries;
    if (entries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (entries.isEmpty) {
      return Center(child: Text(l10n?.noData ?? 'No data'));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n?.uwpLoopbackExplain ?? '',
          style: textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              final busy = _busy.contains(entry.family);
              return SwitchListTile(
                dense: true,
                title: Text(entry.name),
                subtitle: Text(
                  entry.family,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                value: entry.exempt,
                onChanged: busy ? null : (value) => _setExemption(entry, value),
                secondary: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              );
            },
          ),
        ),
      ],
    );
  }
}
