import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/grey_option.dart';
import '../../../app/settings_row.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/appearance_controller.dart';
import '../domain/appearance_settings.dart';
import '../domain/custom_theme.dart';
import 'appearance_labels.dart';
import 'chat_preview.dart';
import 'custom_theme_actions.dart';
import 'wallpaper_page.dart';

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
                    _ThemeTile(
                      id: id,
                      selected:
                          look.customThemeId == null && look.themeId == id,
                    ),
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
            for (final c in look.customThemes)
              _CustomThemeRow(theme: c, selected: look.customThemeId == c.id),
            GreyOption(
              name: 'custom',
              label: l.appearanceNewTheme,
              child: SisSettingsRow(
                icon: Icons.add_rounded,
                title: l.appearanceNewTheme,
              ),
            ),
            SisSettingsRow(
              key: const ValueKey('appearance-wallpaper'),
              icon: Icons.wallpaper_outlined,
              title: l.appearanceWallpaper,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const WallpaperPage()),
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
        onLongPress: () => duplicateBuiltInTheme(
          ref,
          AppLocalizations.of(context),
          Theme.of(context).brightness,
          id,
        ),
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

class _CustomThemeRow extends ConsumerWidget {
  const _CustomThemeRow({required this.theme, required this.selected});

  final CustomTheme theme;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = SisBrand.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          key: ValueKey('custom-theme-${theme.id}'),
          onTap: () =>
              ref.read(appearanceProvider.notifier).selectCustomTheme(theme.id),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: SisTokens.settingsRowPadding,
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(theme.accent),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      theme.name,
                      style: Theme.of(context).textTheme.bodyLarge,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  if (selected) Icon(Icons.check_rounded, color: t.brand),
                  Builder(
                    builder: (ctx) => IconButton(
                      key: ValueKey('custom-theme-menu-${theme.id}'),
                      tooltip: AppLocalizations.of(ctx).appearanceThemeMenu,
                      icon: Icon(Icons.more_vert_rounded, color: t.muted),
                      onPressed: () {
                        final box = ctx.findRenderObject() as RenderBox;
                        final anchor =
                            box.localToGlobal(Offset.zero) & box.size;
                        openCustomThemeMenu(ctx, ref, theme, anchor);
                      },
                    ),
                  ),
                ],
              ),
            ),
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
