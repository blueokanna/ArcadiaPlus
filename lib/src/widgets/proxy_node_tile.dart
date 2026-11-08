import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/theme/app_motion.dart';
import 'package:arcadiaplus/src/theme/app_shapes.dart';
import 'package:arcadiaplus/src/widgets/adaptive_button.dart';

/// Material owns focus, keyboard activation, ink and disabled semantics.
/// Selection changes color without changing the card's geometry.
class ProxyNodeTile extends StatelessWidget {
  const ProxyNodeTile({
    super.key,
    required this.name,
    required this.subtitle,
    required this.selected,
    required this.onPressed,
    this.latency,
    this.failed = false,
    this.icon = Icons.public_rounded,
  });

  final String name;
  final String subtitle;
  final bool selected;
  final VoidCallback? onPressed;
  final String? latency;
  final bool failed;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final foreground = selected
        ? colors.onSecondaryContainer
        : colors.onSurface;
    return Semantics(
      selected: selected,
      child: AdaptiveButton(
        onPressed: onPressed,
        style: ButtonStyle(
          animationDuration: AppMotion.duration(context, AppMotion.short),
          padding: const WidgetStatePropertyAll(EdgeInsets.all(12)),
          minimumSize: const WidgetStatePropertyAll(Size(48, 104)),
          alignment: Alignment.centerLeft,
          shape: const WidgetStatePropertyAll(AppShapes.card),
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: WidgetStatePropertyAll(
            selected ? colors.secondaryContainer : colors.surfaceContainerLow,
          ),
          foregroundColor: WidgetStatePropertyAll(foreground),
          side: WidgetStatePropertyAll(
            BorderSide(
              color: selected ? colors.secondary : colors.outlineVariant,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 22),
                const Spacer(),
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  size: 22,
                  color: selected ? colors.secondary : colors.outline,
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.titleSmall?.copyWith(color: foreground),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelMedium?.copyWith(
                    color: selected
                        ? colors.onSecondaryContainer
                        : colors.onSurfaceVariant,
                  ),
                ),
                if (latency != null)
                  Text(
                    latency!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelMedium?.copyWith(
                      color: failed ? colors.error : foreground,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
