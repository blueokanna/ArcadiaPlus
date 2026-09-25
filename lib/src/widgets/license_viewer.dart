import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:arcadiaplus/src/l10n/app_localizations.dart';

/// The licence file, read once per run: it is a few kilobytes of static text
/// and the dialog is expected to open instantly.
String? _licenseText;

/// Shows the licence that ships with the app, verbatim.
///
/// The text is read from the bundled `LICENSE` file rather than kept as a copy
/// in Dart: a licence page quoting a stale copy of its own licence is worse
/// than no page at all, and this one is a source-available licence whose terms
/// a reader needs exactly as written.
Future<void> showBundledLicense(BuildContext context) async {
  final l10n = AppLocalizations.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final errorColor = Theme.of(context).colorScheme.error;

  try {
    final text = _licenseText ?? await rootBundle.loadString('LICENSE');
    _licenseText = text;
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n?.licenseName ?? 'PolyForm Perimeter 1.0.1'),
        content: SizedBox(
          width: 560,
          height: 420,
          child: Scrollbar(
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  height: 1.5,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n?.close ?? 'Close'),
          ),
        ],
      ),
    );
  } catch (e) {
    debugPrint('Failed to read the bundled licence: $e');
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${l10n?.license ?? 'License'}: ${l10n?.failed ?? 'Failed'} — $e',
        ),
        behavior: SnackBarBehavior.floating,
        backgroundColor: errorColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}
