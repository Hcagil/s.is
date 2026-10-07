import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/settings_row.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/appearance_controller.dart';
import '../domain/appearance_settings.dart';
import '../domain/wallpaper.dart';
import '../domain/wallpaper_photos.dart';
import '../../chat/presentation/message_menu_card.dart';
import 'chat_preview.dart';

/// Page for selecting the wallpaper and related settings.
class WallpaperPage extends ConsumerWidget {
  const WallpaperPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = ref.watch(appearanceProvider);
    final notifier = ref.read(appearanceProvider.notifier);
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);

    final int initialTabIndex = switch (look.wallpaper.kind) {
      WallpaperKind.none || WallpaperKind.colour => 0,
      WallpaperKind.gradient => 1,
      WallpaperKind.picture => 2,
    };

    return Scaffold(
      appBar: AppBar(title: Text(l.appearanceWallpaper)),
      body: SafeArea(
        child: DefaultTabController(
          length: 3,
          initialIndex: initialTabIndex,
          child: Column(
            children: [
              SizedBox(height: 240, child: const ChatPreview()),
              TabBar(
                tabs: [
                  Tab(
                    key: const ValueKey('wallpaper-tab-colour'),
                    text: l.wallpaperColour,
                  ),
                  Tab(
                    key: const ValueKey('wallpaper-tab-gradient'),
                    text: l.wallpaperGradient,
                  ),
                  Tab(
                    key: const ValueKey('wallpaper-tab-picture'),
                    text: l.wallpaperPicture,
                  ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    colourPane(look, notifier, l, t),
                    gradientPane(look, notifier, l, t),
                    picturePane(look, notifier, l, t, context),
                  ],
                ),
              ),
              const _ResetBlock(),
            ],
          ),
        ),
      ),
    );
  }
}

Widget colourPane(
  AppearanceSettings look,
  AppearanceController notifier,
  AppLocalizations l,
  SisBrand t,
) {
  final List<int> colours = [
    0xFF0D0B22,
    0xFF1D1A42,
    0xFF102A43,
    0xFF12351F,
    0xFF3A1A1A,
    0xFF2B2B2B,
    0xFFF5F4FA,
    0xFFE8D9FF,
  ];

  return SingleChildScrollView(
    padding: const EdgeInsets.only(top: 12),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (int i = 0; i < colours.length; i++)
            _Swatch(
              key: ValueKey('wallpaper-colour-$i'),
              color: Color(colours[i]),
              selected:
                  look.wallpaper.kind == WallpaperKind.colour &&
                  look.wallpaper.colours.isNotEmpty &&
                  look.wallpaper.colours[0] == colours[i],
              onTap: () => notifier.setWallpaper(
                look.wallpaper.copyWith(
                  kind: WallpaperKind.colour,
                  colours: [colours[i]],
                ),
              ),
              t: t,
            ),
        ],
      ),
    ),
  );
}

Widget gradientPane(
  AppearanceSettings look,
  AppearanceController notifier,
  AppLocalizations l,
  SisBrand t,
) {
  final List<List<int>> gradients = [
    [0xFF3D4BE8, 0xFF0D0B22],
    [0xFF7B6BFF, 0xFF1D1A42],
    [0xFF38B6FF, 0xFF0A1626],
    [0xFFFF8A5B, 0xFF1C0C1E],
    [0xFF4CC38A, 0xFF0A1A14],
    [0xFFF06292, 0xFF1A0A14],
  ];

  return SingleChildScrollView(
    padding: const EdgeInsets.only(top: 12),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (int i = 0; i < gradients.length; i++)
            _Swatch(
              key: ValueKey('wallpaper-gradient-$i'),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [for (final c in gradients[i]) Color(c)],
              ),
              selected:
                  look.wallpaper.kind == WallpaperKind.gradient &&
                  look.wallpaper.colours.length == 2 &&
                  look.wallpaper.colours[0] == gradients[i][0] &&
                  look.wallpaper.colours[1] == gradients[i][1],
              onTap: () => notifier.setWallpaper(
                look.wallpaper.copyWith(
                  kind: WallpaperKind.gradient,
                  colours: gradients[i],
                ),
              ),
              t: t,
            ),
        ],
      ),
    ),
  );
}

Widget picturePane(
  AppearanceSettings look,
  AppearanceController notifier,
  AppLocalizations l,
  SisBrand t,
  BuildContext context,
) {
  return SingleChildScrollView(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (look.wallpaper.picturePath != null)
                _PictureTile(
                  key: const ValueKey('wallpaper-picture-current'),
                  path: look.wallpaper.picturePath!,
                  selected: look.wallpaper.kind == WallpaperKind.picture,
                  onTap: () => notifier.setWallpaper(
                    look.wallpaper.copyWith(kind: WallpaperKind.picture),
                  ),
                  t: t,
                ),
              _ChoosePhotoChip(
                key: const ValueKey('wallpaper-choose-photo'),
                label: l.wallpaperChoosePhoto,
                onTap: () async {
                  final r = await notifier.pickWallpaperPicture();
                  if (r is WallpaperPickFailed && context.mounted) {
                    showSisNotice(
                      context,
                      l.wallpaperPickFailed,
                      isError: true,
                    );
                  }
                },
              ),
            ],
          ),
        ),
        _SliderRow(
          sliderKey: const ValueKey('wallpaper-dim'),
          label: l.appearanceDim,
          valueText: look.wallpaper.dim.toStringAsFixed(2),
          value: look.wallpaper.dim,
          max: 0.8,
          divisions: 16,
          onChanged: notifier.setWallpaperDim,
        ),
        _SliderRow(
          sliderKey: const ValueKey('wallpaper-blur'),
          label: l.appearanceBlur,
          valueText: look.wallpaper.blur.round().toString(),
          value: look.wallpaper.blur,
          max: 12,
          divisions: 12,
          onChanged: notifier.setWallpaperBlur,
        ),
        const SizedBox(height: 24),
      ],
    ),
  );
}

/// A label with its value on the right and a slider under it.
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.sliderKey,
    required this.label,
    required this.valueText,
    required this.value,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final Key sliderKey;
  final String label;
  final String valueText;
  final double value;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
              ),
              Text(valueText, style: const TextStyle(fontSize: 13.5)),
            ],
          ),
          Slider(
            key: sliderKey,
            value: value,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

/// A round swatch for selecting a wallpaper colour or gradient.
class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    this.color,
    this.gradient,
    required this.selected,
    required this.onTap,
    required this.t,
  });

  final Color? color;
  final Gradient? gradient;
  final bool selected;
  final VoidCallback onTap;
  final SisBrand t;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: SizedBox(
        width: 38,
        height: 38,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(19),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
              gradient: gradient,
              border: Border.all(color: selected ? t.brand : t.line, width: 2),
              boxShadow: selected
                  ? [BoxShadow(color: t.glow, spreadRadius: 2)]
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// The picture already chosen, as a tile.
class _PictureTile extends StatelessWidget {
  const _PictureTile({
    super.key,
    required this.path,
    required this.selected,
    required this.onTap,
    required this.t,
  });

  final String path;
  final bool selected;
  final VoidCallback onTap;
  final SisBrand t;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: SizedBox(
        width: 72,
        height: 38,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: selected ? t.brand : t.line, width: 2),
              boxShadow: selected
                  ? [BoxShadow(color: t.glow, spreadRadius: 2)]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The "Choose photo" chip.
class _ChoosePhotoChip extends StatelessWidget {
  const _ChoosePhotoChip({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(minWidth: 72, minHeight: 38),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: t.muted,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
        ),
      ),
    );
  }
}

/// The "Reset Chat Backgrounds" row and its info line.
class _ResetBlock extends ConsumerWidget {
  const _ResetBlock();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final notifier = ref.read(appearanceProvider.notifier);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Builder(
          builder: (rowContext) => SisSettingsRow(
            key: const ValueKey('wallpaper-reset'),
            icon: Icons.restart_alt_rounded,
            title: l.wallpaperReset,
            onTap: () async {
              final box = rowContext.findRenderObject() as RenderBox;
              final anchor = box.localToGlobal(Offset.zero) & box.size;
              final ok = await showFloatingCard<bool>(
                rowContext,
                anchor: anchor,
                highlightAnchor: false,
                cardKey: const ValueKey('wallpaper-reset-card'),
                child: const _ResetCardBody(),
              );
              if (ok == true) await notifier.resetWallpaper();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            l.wallpaperResetInfo,
            style: TextStyle(color: SisBrand.of(context).muted, fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}

class _ResetCardBody extends StatelessWidget {
  const _ResetCardBody();

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SizedBox(
      width: 280,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.wallpaperResetTitle,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Text(l.wallpaperResetConfirm),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('wallpaper-reset-cancel'),
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(l.appearanceCancel),
                ),
                TextButton(
                  key: const ValueKey('wallpaper-reset-confirm'),
                  onPressed: () => Navigator.of(context).pop(true),
                  child: Text(
                    l.wallpaperResetAction,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
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
