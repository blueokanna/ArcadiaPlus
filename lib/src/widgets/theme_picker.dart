import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/widgets/adaptive_button.dart';
import 'package:arcadiaplus/src/l10n/app_localizations.dart';
import 'package:arcadiaplus/src/providers/theme_provider.dart';

import '../theme/palette_reference.dart';
import '../theme/app_shapes.dart';

Future<void> showThemePicker(BuildContext context, ThemeProvider provider) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => ThemePicker(provider: provider),
  );
}

class ThemePicker extends StatelessWidget {
  const ThemePicker({super.key, required this.provider});
  final ThemeProvider provider;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: provider,
    builder: (context, _) {
      final l10n = AppLocalizations.of(context);
      final theme = Theme.of(context);
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      return SizedBox(
        height: MediaQuery.sizeOf(context).height * .75,
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
              sliver: SliverToBoxAdapter(
                child: Text(
                  l10n?.chooseTheme ?? 'Choose theme',
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              sliver: SliverLayoutBuilder(
                builder: (context, constraints) {
                  final columns =
                      constraints.crossAxisExtent >= 280 && scale < 1.5 ? 2 : 1;
                  return SliverGrid.builder(
                    itemCount: provider.availableThemes.length,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      mainAxisExtent: 110 + 56 * scale,
                    ),
                    itemBuilder: (context, index) {
                      final name = provider.availableThemes[index];
                      final colors = provider.getThemePreviewScheme(
                        name,
                        theme.brightness,
                      );
                      final selected = provider.selectedTheme == name;
                      return Semantics(
                        selected: selected,
                        child: AdaptiveButton(
                          onPressed: () {
                            provider.setUseDynamicColors(false);
                            provider.setTheme(name);
                            Navigator.of(context).pop();
                          },
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.all(12),
                            backgroundColor: colors.surfaceContainerHigh,
                            foregroundColor: colors.onSurface,
                            shape: RoundedRectangleBorder(
                              borderRadius: AppShapes.extraLarge,
                            ),
                            side: BorderSide(
                              color: selected
                                  ? colors.primary
                                  : colors.outlineVariant,
                              width: selected ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ClipRRect(
                                borderRadius: AppShapes.medium,
                                child: SizedBox(
                                  height: 40,
                                  child: Row(
                                    children: [
                                      for (final color in [
                                        colors.primary,
                                        colors.secondary,
                                        colors.tertiary,
                                      ])
                                        Expanded(
                                          child: ColoredBox(
                                            color: color,
                                            child: const SizedBox.expand(),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      l10n?.paletteName(name) ??
                                          provider.getThemeDisplayName(name),
                                      maxLines: 2,
                                      style: theme.textTheme.labelLarge
                                          ?.copyWith(color: colors.onSurface),
                                    ),
                                  ),
                                  if (selected) ...[
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.check_circle,
                                      size: 20,
                                      color: colors.primary,
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                PaletteReference.forTheme(name).label,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
              sliver: SliverToBoxAdapter(
                child: SwitchListTile(
                  title: Text(l10n?.dynamicColors ?? 'Dynamic colors'),
                  subtitle: provider.dynamicColorAvailable == false
                      ? Text(
                          l10n?.dynamicColorUnavailable ??
                              'Unavailable on this device',
                        )
                      : null,
                  value: provider.useDynamicColors,
                  onChanged: provider.dynamicColorAvailable == false
                      ? null
                      : provider.setUseDynamicColors,
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              sliver: SliverToBoxAdapter(
                child: Text(
                  l10n?.paletteScreenNote ??
                      'Screen colors adapted from the supplied print chart.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
