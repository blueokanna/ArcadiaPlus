import 'package:flutter/foundation.dart';

import 'config_converter.dart';
import 'storage_service.dart';

void _validate((String, DnsSettings) input) =>
    ConfigConverter.validateDns(input.$1, input.$2);

/// Shared by preflight and persisted privacy changes. YAML parsing stays off
/// the UI isolate, and validation uses the runtime conversion boundary.
abstract final class DnsConfigurationValidator {
  static Future<String?> readActiveProfile() async {
    final store = StorageService.instance;
    final id = await store.getActiveProfileId();
    return id == null ? null : store.getProfileConfig(id);
  }

  static Future<void> validate(String profile, DnsSettings settings) =>
      compute(_validate, (profile, settings));

  static Future<void> validateActiveProfile(DnsSettings settings) async {
    final profile = await readActiveProfile();
    if (profile != null) await validate(profile, settings);
  }
}
