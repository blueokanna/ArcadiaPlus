import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:arcadiaplus/src/utils/platform_utils.dart';
import 'package:arcadiaplus/src/utils/animation_utils.dart';
import 'package:arcadiaplus/src/theme/app_motion.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';

typedef _Destination = ({
  String path,
  String label,
  IconData icon,
  IconData selected,
});

/// Labels, selection, keyboard navigation and routes share one source of truth.
class AppNavigationBar extends StatelessWidget {
  final ValueChanged<int>? onDestinationSelected;
  const AppNavigationBar({super.key, this.onDestinationSelected});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    final mobile = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => PlatformUtils.isOHOS,
    };
    final destinations = <_Destination>[
      (
        path: '/',
        label: l10n?.home ?? 'Home',
        icon: Icons.space_dashboard_outlined,
        selected: Icons.space_dashboard_rounded,
      ),
      (
        path: '/proxies',
        label: l10n?.proxies ?? 'Proxies',
        icon: Icons.public_outlined,
        selected: Icons.public_rounded,
      ),
      (
        path: '/profiles',
        label: l10n?.profiles ?? 'Profiles',
        icon: Icons.folder_outlined,
        selected: Icons.folder_rounded,
      ),
      (
        path: '/connections',
        label: l10n?.connectionsShort ?? 'Conns',
        icon: Icons.hub_outlined,
        selected: Icons.hub_rounded,
      ),
      if (!mobile)
        (
          path: '/logs',
          label: l10n?.logs ?? 'Logs',
          icon: Icons.article_outlined,
          selected: Icons.article_rounded,
        ),
      (
        path: '/settings',
        label: l10n?.settings ?? 'Settings',
        icon: Icons.tune_outlined,
        selected: Icons.tune_rounded,
      ),
    ];
    final path = GoRouterState.of(context).uri.path;
    final match = destinations.indexWhere((item) => item.path == path);
    final index = match < 0 ? destinations.length - 1 : match;
    void navigate(int index) {
      if (destinations[index].path == path) return;
      AnimationUtils.selectionHaptic();
      onDestinationSelected?.call(index);
      context.go(destinations[index].path);
    }

    final side = PlatformUtils.shouldUseSideNavigation(context);
    final expanded = MediaQuery.sizeOf(context).width >= 1000;
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final extent = side && expanded
        ? 56.0 + (scale - 1).clamp(0, 2) * 24
        : 66.0 + (scale - 1).clamp(0, 2) * 28;
    final strip = _DestinationStrip(
      destinations: destinations,
      selected: index,
      vertical: side,
      expanded: side && expanded,
      extent: extent,
      onSelected: navigate,
    );
    if (side) {
      return SizedBox(
        width: expanded ? 224 : 88,
        child: SafeArea(
          right: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              expanded ? 12 : 6,
              20,
              expanded ? 12 : 6,
              20,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 28),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: colors.primaryContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.shield_rounded,
                          color: colors.onPrimaryContainer,
                          size: 23,
                        ),
                      ),
                      if (expanded) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'ArcadiaPlus',
                            maxLines: 2,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                strip,
              ],
            ),
          ),
        ),
      );
    }
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Align(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(36),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Material(
                key: const ValueKey('floating-navigation'),
                color: colors.surfaceContainerLow.withValues(alpha: .72),
                elevation: 0,
                shadowColor: colors.shadow.withValues(alpha: 0.18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(36),
                  side: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: 0.35),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: Padding(padding: const EdgeInsets.all(6), child: strip),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Only the indicator moves each frame. Destination buttons and routed content
/// remain outside the animation builder, including during an interrupted spring.
class _DestinationStrip extends StatefulWidget {
  const _DestinationStrip({
    required this.destinations,
    required this.selected,
    required this.vertical,
    required this.expanded,
    required this.extent,
    required this.onSelected,
  });
  final List<_Destination> destinations;
  final int selected;
  final bool vertical;
  final bool expanded;
  final double extent;
  final ValueChanged<int> onSelected;
  @override
  State<_DestinationStrip> createState() => _DestinationStripState();
}

class _DestinationStripState extends State<_DestinationStrip>
    with SingleTickerProviderStateMixin {
  late final _position = AnimationController.unbounded(
    vsync: this,
    value: widget.selected.toDouble(),
  );

  @override
  void didUpdateWidget(_DestinationStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      if (MediaQuery.disableAnimationsOf(context) ||
          !TickerMode.valuesOf(context).enabled) {
        _position.value = widget.selected.toDouble();
      } else {
        _position.animateWith(
          SpringSimulation(
            AppMotion.spatialSpring,
            _position.value,
            widget.selected.toDouble(),
            _position.velocity,
            tolerance: const Tolerance(distance: 0.001, velocity: 0.001),
          ),
        );
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _position.value = widget.selected.toDouble();
    }
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final buttons = [
      for (var i = 0; i < widget.destinations.length; i++) _button(context, i),
    ];
    void step(int delta) => widget.onSelected(
      (widget.selected + delta) % widget.destinations.length,
    );
    return CallbackShortcuts(
      bindings: {
        SingleActivator(
          widget.vertical
              ? LogicalKeyboardKey.arrowDown
              : LogicalKeyboardKey.arrowRight,
        ): () => step(
          Directionality.of(context) == TextDirection.rtl && !widget.vertical
              ? -1
              : 1,
        ),
        SingleActivator(
          widget.vertical
              ? LogicalKeyboardKey.arrowUp
              : LogicalKeyboardKey.arrowLeft,
        ): () => step(
          Directionality.of(context) == TextDirection.rtl && !widget.vertical
              ? 1
              : -1,
        ),
        const SingleActivator(LogicalKeyboardKey.home): () =>
            widget.onSelected(0),
        const SingleActivator(LogicalKeyboardKey.end): () =>
            widget.onSelected(widget.destinations.length - 1),
      },
      child: SizedBox(
        height: widget.vertical
            ? widget.extent * buttons.length
            : widget.extent,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final cellWidth = widget.vertical
                ? constraints.maxWidth
                : constraints.maxWidth / buttons.length;
            final reverse =
                !widget.vertical &&
                Directionality.of(context) == TextDirection.rtl;
            return RepaintBoundary(
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    top: 0,
                    width: cellWidth,
                    height: widget.extent,
                    child: AnimatedBuilder(
                      animation: _position,
                      builder: (context, child) {
                        final position = _position.value.clamp(
                          0.0,
                          buttons.length - 1.0,
                        );
                        return Transform.translate(
                          offset: Offset(
                            widget.vertical
                                ? 0
                                : (reverse
                                          ? buttons.length - 1 - position
                                          : position) *
                                      cellWidth,
                            widget.vertical ? position * widget.extent : 0,
                          ),
                          child: child!,
                        );
                      },
                      child: Padding(
                        padding: widget.expanded
                            ? const EdgeInsets.symmetric(vertical: 4)
                            : const EdgeInsets.symmetric(horizontal: 2),
                        child: DecoratedBox(
                          key: const ValueKey('navigation-indicator'),
                          decoration: BoxDecoration(
                            color: colors.secondaryContainer,
                            borderRadius: BorderRadius.circular(
                              widget.expanded ? 18 : 30,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (widget.vertical)
                    Column(children: buttons)
                  else
                    Row(
                      children: [
                        for (final button in buttons) Expanded(child: button),
                      ],
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _button(BuildContext context, int index) {
    final item = widget.destinations[index];
    final selected = index == widget.selected;
    final colors = Theme.of(context).colorScheme;
    final label = Text(
      item.label,
      maxLines: widget.expanded ? 2 : 1,
      overflow: TextOverflow.ellipsis,
      textAlign: widget.expanded ? TextAlign.start : TextAlign.center,
    );
    final icon = Icon(
      selected ? item.selected : item.icon,
      size: widget.expanded ? 22 : 24,
    );
    return Semantics(
      selected: selected,
      child: Tooltip(
        message: item.label,
        excludeFromSemantics: true,
        child: SizedBox(
          height: widget.extent,
          width: double.infinity,
          child: TextButton(
            key: ValueKey('nav-${item.path}'),
            onPressed: () => widget.onSelected(index),
            style: TextButton.styleFrom(
              foregroundColor: selected
                  ? colors.onSecondaryContainer
                  : colors.onSurfaceVariant,
              textStyle:
                  (widget.expanded
                          ? Theme.of(context).textTheme.labelLarge
                          : Theme.of(context).textTheme.labelSmall)
                      ?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
              padding: EdgeInsets.symmetric(
                horizontal: widget.expanded ? 16 : 2,
                vertical: 4,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(widget.expanded ? 18 : 30),
              ),
              minimumSize: const Size(48, 48),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: widget.expanded
                ? Row(
                    children: [
                      icon,
                      const SizedBox(width: 14),
                      Expanded(child: label),
                    ],
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [icon, const SizedBox(height: 4), label],
                  ),
          ),
        ),
      ),
    );
  }
}
