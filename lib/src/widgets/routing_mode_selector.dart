import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/services/platform_proxy_service.dart';

/// One selection model for touch, mouse, keyboard and assistive technology.
class RoutingModeSelector extends StatelessWidget {
  const RoutingModeSelector({super.key, required this.mode, this.onChanged});
  final ProxyMode mode;
  final ValueChanged<ProxyMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final vertical =
            constraints.maxWidth < 360 ||
            MediaQuery.textScalerOf(context).scale(14) > 19;
        return SegmentedButton<ProxyMode>(
          direction: vertical ? Axis.vertical : Axis.horizontal,
          expandedInsets: vertical ? null : EdgeInsets.zero,
          showSelectedIcon: false,
          segments: [
            ButtonSegment(
              value: ProxyMode.rule,
              icon: vertical ? const Icon(Icons.rule_rounded) : null,
              label: Text(l10n?.ruleMode ?? 'Rule Mode'),
            ),
            ButtonSegment(
              value: ProxyMode.global,
              icon: vertical ? const Icon(Icons.public_rounded) : null,
              label: Text(l10n?.globalProxy ?? 'Global Proxy'),
            ),
            ButtonSegment(
              value: ProxyMode.direct,
              icon: vertical ? const Icon(Icons.alt_route_rounded) : null,
              label: Text(l10n?.directModeName ?? 'Direct Mode'),
            ),
          ],
          selected: {mode},
          onSelectionChanged: onChanged == null
              ? null
              : (selection) => onChanged!(selection.single),
          style: const ButtonStyle(
            minimumSize: WidgetStatePropertyAll(Size(48, 48)),
          ),
        );
      },
    );
  }
}
