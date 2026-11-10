import 'package:flutter/material.dart';

/// Expressive action on the OHOS SDK, which predates the standalone Material
/// library. Uses the SDK button for focus, semantics, ink and gesture handling.
class ExpressiveAction extends StatelessWidget {
  const ExpressiveAction({
    super.key,
    required this.onPressed,
    required this.child,
    this.selected = false,
  });

  final VoidCallback? onPressed;
  final Widget child;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final foreground = selected ? colors.onPrimary : colors.onSurface;
    return FilledButton(
      onPressed: onPressed,
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size(48, 56)),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        ),
        textStyle: WidgetStatePropertyAll(theme.textTheme.labelLarge),
        elevation: const WidgetStatePropertyAll(0),
        animationDuration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 200),
        shape: WidgetStateProperty.resolveWith((states) {
          // One Material surface interpolates its outline during a press.
          final radius = states.contains(WidgetState.pressed)
              ? 12.0
              : selected
              ? 28.0
              : 16.0;
          return RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
          );
        }),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? colors.onSurface.withValues(alpha: 0.12)
              : selected
              ? colors.primary
              : colors.surfaceContainerHighest,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? colors.onSurface.withValues(alpha: 0.38)
              : foreground,
        ),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) return Colors.transparent;
          if (states.contains(WidgetState.pressed) ||
              states.contains(WidgetState.focused)) {
            return foreground.withValues(alpha: 0.10);
          }
          if (states.contains(WidgetState.hovered)) {
            return foreground.withValues(alpha: 0.08);
          }
          return Colors.transparent;
        }),
      ),
      child: child,
    );
  }
}
