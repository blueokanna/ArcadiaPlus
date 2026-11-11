import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/theme/app_motion.dart';
import 'package:arcadiaplus/src/theme/app_shapes.dart';
import 'package:arcadiaplus/src/widgets/adaptive_button.dart';

import 'expressive_shape.dart';

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
    this.selectable = true,
  });

  final String name;
  final String subtitle;
  final bool selected;
  final VoidCallback? onPressed;
  final String? latency;
  final bool failed;
  final IconData icon;
  final bool selectable;

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
          padding: const WidgetStatePropertyAll(EdgeInsets.all(16)),
          minimumSize: const WidgetStatePropertyAll(Size(48, 96)),
          alignment: Alignment.centerLeft,
          shape: const WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: AppShapes.large),
          ),
          elevation: const WidgetStatePropertyAll(0),
          backgroundColor: WidgetStatePropertyAll(
            selected ? colors.secondaryContainer : colors.surfaceContainerLow,
          ),
          foregroundColor: WidgetStatePropertyAll(foreground),
          side: WidgetStatePropertyAll(
            BorderSide(
              color: selected
                  ? colors.primary
                  : colors.outlineVariant.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 200;
            final nameLabel = Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.titleSmall?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            );
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    AnimatedExpressiveShape(
                      progress: selected ? 1 : 0,
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: selected
                              ? colors.primary
                              : colors.surfaceContainer,
                        ),
                        child: Icon(
                          icon,
                          size: 19,
                          color: selected
                              ? colors.onPrimary
                              : colors.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (compact)
                      const Spacer()
                    else ...[
                      const SizedBox(width: 10),
                      Expanded(child: nameLabel),
                    ],
                    const SizedBox(width: 8),
                    if (selectable)
                      Icon(
                        selected
                            ? Icons.check_circle_rounded
                            : Icons.circle_outlined,
                        size: 22,
                        color: selected ? colors.secondary : colors.outline,
                      ),
                  ],
                ),
                if (compact) ...[const SizedBox(height: 8), nameLabel],
                const SizedBox(height: 12),
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
            );
          },
        ),
      ),
    );
  }
}
