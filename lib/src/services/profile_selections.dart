import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:arcadiaplus/src/services/proxy_engine_service.dart';
import 'package:arcadiaplus/src/services/proxy_selection_service.dart';

abstract final class ProfileSelections {
  static String key(String? profileId, String group) => profileId == null
      ? 'selected_proxy_$group'
      : 'profile.${Uri.encodeComponent(profileId)}.selection.${Uri.encodeComponent(group)}';

  static String groupKey(String? profileId) => profileId == null
      ? 'selected_proxy_group'
      : 'profile.${Uri.encodeComponent(profileId)}.selectedGroup';

  /// Restore before opening listeners, including selectors whose screen has
  /// never been visited. Unscoped legacy choices cannot identify their profile.
  static Future<void> restore(
    String profileId,
    String config,
    ProxyEngine engine,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final document = jsonDecode(config) as Map<String, dynamic>;
    final selection = ProxySelectionService(engine);
    for (final outbound in document['outbounds'] as List) {
      if (outbound['outbound_type'] != 'selector') continue;
      final group = outbound['tag'] as String;
      final options = jsonDecode(outbound['options'] as String) as Map;
      final members = (options['outbounds'] as List).cast<String>();
      if (members.isEmpty) continue;
      final saved = prefs.getString(key(profileId, group));
      final member = members.contains(saved) ? saved! : members.first;
      final result = await selection.select(
        group,
        member,
        isCurrent: () => true,
      );
      if (result == null || result.error != null || result.member != member) {
        throw StateError('Cannot restore routing group "$group" to "$member"');
      }
    }
  }
}
