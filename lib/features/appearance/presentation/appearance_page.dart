import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/grey_option.dart';
import '../../../app/settings_row.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/appearance_controller.dart';
import '../domain/appearance_settings.dart';
import 'appearance_labels.dart';
import 'chat_preview.dart';

class AppearancePage extends ConsumerWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = ref.watch(appearanceProvider);
    final l = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsAppearance)),
      body: SafeArea(
        child: ListView(
          children: [
            const ChatPreview(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                l.appearanceBuiltIn,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: SisTokens.sectionLabelWeight,
                  color: SisBrand.of(context).muted,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GridView.count(
                crossAxisCount: 3,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 0.95,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  for (final id in AppThemeId.values)
                    _ThemeTile(id: id, selected: look.themeId == id),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Text(
                l.appearanceMyThemes,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: SisTokens.sectionLabelWeight,
                  color: SisBrand.of(context).muted,
                ),
              ),
            ),
            GreyOption(
              name: 'custom',
              label: l.appearanceMyThemes,
              child: SisSettingsRow(
                icon: Icons.add_rounded,
                title: l.appearanceNewTheme,
              ),
            ),
            GreyOption(
              name: 'wallpaper',
              label: l.appearanceWallpaper,
              child: SisSettingsRow(
                icon: Icons.wallpaper_outlined,
                title: l.appearanceWallpaper,
              ),
            ),
            GreyOption(
              name: 'dimblur',
              child: Column(
                children: [
                  ListTile(
                    title: Text(l.appearanceDim),
                    subtitle: Slider(value: 0.3, onChanged: null),
                  ),
                  ListTile(
                    title: Text(l.appearanceBlur),
                    subtitle: Slider(value: 0, onChanged: null),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                l.appearanceNoExport,
                key: const ValueKey('appearance-no-export'),
                style: TextStyle(color: SisBrand.of(context).muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThemeTile extends ConsumerWidget {
  final AppThemeId id;
  final bool selected;

  const _ThemeTile({required this.id, required this.selected});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = sisBrandFor(id, Theme.of(context).brightness);
    final t = SisBrand.of(context);

    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        key: ValueKey('theme-${id.name}'),
        borderRadius: BorderRadius.circular(16),
        onTap: () => ref.read(appearanceProvider.notifier).setTheme(id),
        child: Container(
          padding: EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected ? t.brand : t.line,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Stack(
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: ImageFiltered(
                      enabled: !selected,
                      imageFilter: ImageFilter.blur(
                        sigmaX: 3,
                        sigmaY: 3,
                        tileMode: TileMode.decal,
                      ),
                      child: _Swatch(p),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    themeLabel(AppLocalizations.of(context), id),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 12.5,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ),
              if (selected)
                Positioned(
                  right: 0,
                  top: 0,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: t.brand,
                    ),
                    child: Icon(
                      Icons.check_rounded,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  final SisBrand p;

  const _Swatch(this.p);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      child: Container(
        color: p.background,
        child: Stack(
          children: [
            Positioned(
              left: 6,
              top: 8,
              width: 30,
              height: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: p.text.withValues(alpha: 0.28),
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
            ),
            Positioned(
              right: 6,
              bottom: 8,
              width: 34,
              height: 12,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: p.gradient,
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
