import 'package:flutter/material.dart';

import 'adaptive_list_tile.dart';

/// Give a settings picker its own row when a trailing control would leave
/// too little space for readable labels, especially with accessibility text.
class SettingsChoiceTile extends StatelessWidget {
  const SettingsChoiceTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.leading,
    required this.trailing,
    this.compact = false,
  });

  final Widget title;
  final Widget subtitle;
  final Widget leading;
  final Widget trailing;
  final bool compact;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final stacked =
          constraints.maxWidth < (compact ? 300 : 480) ||
          MediaQuery.textScalerOf(context).scale(16) > 20;
      final tile = AdaptiveListTile(
        title: title,
        subtitle: subtitle,
        leading: leading,
        trailing: stacked ? null : trailing,
      );
      if (!stacked) return tile;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          tile,
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: trailing,
            ),
          ),
        ],
      );
    },
  );
}
