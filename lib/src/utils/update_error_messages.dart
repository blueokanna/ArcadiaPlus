import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/services/update_service.dart';

/// A sentence for [error], in the user's language where the case has one.
///
/// The native preflight already decided *what* went wrong; this turns that
/// into the one thing the user needs to read. English is the fallback for the
/// two cases whose text is a diagnostic detail rather than a situation the
/// catalogue names.
String describeUpdateInstallError(
  AppLocalizations? l10n,
  UpdateInstallException error,
) {
  switch (error.block) {
    case UpdateInstallBlock.versionNotNewer:
      final apk = error.apkVersionCode;
      final installed = error.installedVersionCode;
      if (l10n != null && apk != null && installed != null) {
        return l10n.updateSameVersion(apk, installed);
      }
      return 'This build carries version code ${apk ?? '?'}, which is not '
          'newer than the installed ${installed ?? '?'}.';
    case UpdateInstallBlock.signatureMismatch:
      return l10n?.updateSignatureMismatch ??
          'The download is signed with a different key than the installed '
              'app.';
    case UpdateInstallBlock.permissionRequired:
      return l10n?.updatePermissionRequired ??
          'Allow installs from this app in the system settings, then try '
              'again.';
    case UpdateInstallBlock.apkUnreadable:
      return l10n?.updateFailed('the downloaded file could not be read') ??
          'Update failed: the downloaded file could not be read';
    case UpdateInstallBlock.notLaunched:
      return l10n?.updateFailed('the installer did not start') ??
          'Update failed: the installer did not start';
  }
}
