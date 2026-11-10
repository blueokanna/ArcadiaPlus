import 'package:flutter/material.dart';

import 'expressive_action.dart';

import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/services/platform_proxy_service.dart';

/// One selection model for touch, mouse, keyboard and assistive technology.
class RoutingModeSelector extends StatelessWidget {
  const RoutingModeSelector({
    super.key,
    required this.mode,
    this.onChanged,
    this.mobile,
  });
  final ProxyMode mode;
  final ValueChanged<ProxyMode>? onChanged;
  final bool? mobile;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final modes = RoutingModes.available(mobile: mobile);
    return LayoutBuilder(
      builder: (context, constraints) {
        final vertical =
            constraints.maxWidth < (modes.length == 2 ? 260 : 360) ||
            MediaQuery.textScalerOf(context).scale(14) > 19;
        final selected = RoutingModes.restore(mode, mobile: mobile);
        final children = <Widget>[
          for (final value in modes)
            Semantics(
              selected: value == selected,
              inMutuallyExclusiveGroup: true,
              child: ExpressiveAction(
                selected: value == selected,
                onPressed: onChanged == null ? null : () => onChanged!(value),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(switch (value) {
                      ProxyMode.rule => Icons.rule_rounded,
                      ProxyMode.global => Icons.public_rounded,
                      ProxyMode.direct => Icons.alt_route_rounded,
                    }, size: 20),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(switch (value) {
                        ProxyMode.rule => l10n?.ruleMode ?? 'Rule Mode',
                        ProxyMode.global => l10n?.globalProxy ?? 'Global Proxy',
                        ProxyMode.direct =>
                          l10n?.directModeName ?? 'Direct Mode',
                      }, textAlign: TextAlign.center),
                    ),
                  ],
                ),
              ),
            ),
        ];
        return Flex(
          direction: vertical ? Axis.vertical : Axis.horizontal,
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: vertical
              ? CrossAxisAlignment.stretch
              : CrossAxisAlignment.center,
          spacing: 4,
          children: [
            for (final child in children)
              if (vertical) child else Expanded(child: child),
          ],
        );
      },
    );
  }
}
