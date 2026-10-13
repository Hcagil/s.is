import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/appearance_controller.dart';
import '../domain/contrast.dart';
import '../domain/custom_theme.dart';
import 'theme_swatches.dart';

const _defaultAccent = 0xFF7B6BFF;
const _accents = [
  0xFF7B6BFF,
  0xFF38B6FF,
  0xFF4CC38A,
  0xFFFF8A5B,
  0xFF9AA3B2,
  0xFFF06292,
];
const _backgrounds = [0xFF0D0B22, 0xFF1D1A42, 0xFF102A43, 0xFF12351F];
const _mines = [0xFF1D1A42, 0xFFFFFFFF, 0xFFF5F4FA, 0xFFE8D9FF];

/// Colours a new theme: three tabs (accent, chat background, my bubble), a
/// light / dark / auto switch and a live preview. Save makes and selects the
/// theme; Cancel (or back) leaves nothing behind.
class ThemeEditorPage extends ConsumerStatefulWidget {
  const ThemeEditorPage({super.key, required this.name});

  final String name;

  @override
  ConsumerState<ThemeEditorPage> createState() => _ThemeEditorPageState();
}

class _ThemeEditorPageState extends ConsumerState<ThemeEditorPage> {
  int _accent = _defaultAccent;
  int? _background;
  int? _mine;
  CustomThemeMode _mode = CustomThemeMode.light;

  /// 0 accent, 1 background, 2 my messages.
  int _tab = 0;

  bool _dark(BuildContext c) => _mode == CustomThemeMode.automatic
      ? Theme.of(c).brightness == Brightness.dark
      : _mode == CustomThemeMode.dark;

  /// My bubble while none is picked: a deeper shade of the accent.
  int get _deep =>
      Color.lerp(Color(_accent), const Color(0xFF000000), .25)!.toARGB32();

  int _theirs(bool dark) =>
      (dark ? SisBrand.dark : SisBrand.light).theirs.toARGB32();

  SisBrand _draft(bool dark) => sisBrandForCustom(
    CustomTheme(
      id: 'draft',
      name: widget.name,
      mode: _mode,
      accent: _accent,
      mine: _mine ?? _deep,
      theirs: _theirs(dark),
      background: _background,
    ),
    dark ? Brightness.dark : Brightness.light,
  );

  void _reset() => setState(() {
    _accent = _defaultAccent;
    _background = null;
    _mine = null;
    _mode = CustomThemeMode.light;
  });

  Future<void> _save() async {
    final navigator = Navigator.of(context);
    await ref
        .read(appearanceProvider.notifier)
        .createCustomTheme(
          name: widget.name,
          mode: _mode,
          accent: _accent,
          mine: _mine ?? _deep,
          theirs: _theirs(_dark(context)),
          background: _background,
        );
    if (mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final draft = _draft(_dark(context));
    final chat = _background == null ? draft.background : Color(_background!);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(
            key: const ValueKey('editor-save-top'),
            onPressed: _save,
            child: Text(l.commonSave),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: t.line)),
              ),
              child: Row(
                children: [
                  for (final (i, key, label) in [
                    (0, 'editor-tab-accent', l.themeTabAccent),
                    (1, 'editor-tab-background', l.themeTabBackground),
                    (2, 'editor-tab-mine', l.themeTabMyMessages),
                  ])
                    Expanded(
                      child: _Tab(
                        key: ValueKey(key),
                        label: label,
                        selected: _tab == i,
                        onTap: () => setState(() => _tab = i),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              key: const ValueKey('editor-preview'),
              color: chat,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 8,
                children: [
                  _PreviewBubble(
                    key: const ValueKey('editor-preview-theirs'),
                    text: l.previewTheirs,
                    mine: false,
                    brand: draft,
                  ),
                  _PreviewBubble(
                    key: const ValueKey('editor-preview-mine'),
                    text: l.previewMine,
                    mine: true,
                    brand: draft,
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Label(switch (_tab) {
                      0 => l.themePickAccent,
                      1 => l.themePickBackground,
                      _ => l.themePickMine,
                    }),
                    const SizedBox(height: 8),
                    switch (_tab) {
                      0 => ThemeSwatchRow(
                        group: 'accent',
                        colours: _accents,
                        selected: _accent,
                        onPick: (c) => setState(() => _accent = c),
                      ),
                      1 => ThemeSwatchRow(
                        group: 'background',
                        colours: _backgrounds,
                        selected: _background,
                        onPick: (c) => setState(() => _background = c),
                      ),
                      _ => ThemeSwatchRow(
                        group: 'mine',
                        colours: _mines,
                        selected: _mine,
                        onPick: (c) => setState(() => _mine = c),
                      ),
                    },
                    if (_tab == 0 && accentHardToRead(_accent, chat.toARGB32()))
                      Container(
                        key: const ValueKey('editor-contrast-warning'),
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: t.danger.withValues(alpha: .1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          l.themeLowContrast,
                          style: TextStyle(color: t.danger, fontSize: 12),
                        ),
                      ),
                    const SizedBox(height: 20),
                    _Label(l.themeModeLabel),
                    const SizedBox(height: 8),
                    SegmentedButton<CustomThemeMode>(
                      key: const ValueKey('editor-mode'),
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: CustomThemeMode.light,
                          label: Text(l.themeModeLight),
                        ),
                        ButtonSegment(
                          value: CustomThemeMode.dark,
                          label: Text(l.themeModeDark),
                        ),
                        ButtonSegment(
                          value: CustomThemeMode.automatic,
                          label: Text(l.themeModeAuto),
                        ),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (s) =>
                          setState(() => _mode = s.first),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                spacing: 8,
                children: [
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('editor-cancel'),
                      onPressed: () => Navigator.of(context).pop(),
                      style: _buttonStyle,
                      child: Text(
                        l.appearanceCancel,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                      ),
                    ),
                  ),
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('editor-reset'),
                      onPressed: _reset,
                      style: _buttonStyle,
                      child: Text(
                        l.themeReset,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                      ),
                    ),
                  ),
                  Expanded(
                    child: FilledButton(
                      key: const ValueKey('editor-save'),
                      onPressed: _save,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 50),
                      ),
                      child: Text(l.commonSave),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final _buttonStyle = OutlinedButton.styleFrom(
  minimumSize: const Size(0, 50),
  padding: const EdgeInsets.symmetric(horizontal: 8),
);

class _Tab extends StatelessWidget {
  const _Tab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? t.brand : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            color: selected ? t.brand : t.muted,
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      fontWeight: FontWeight.w700,
      fontSize: 12,
      color: SisBrand.of(context).muted,
    ),
  );
}

/// One sample bubble painted from the draft colours.
class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({
    super.key,
    required this.text,
    required this.mine,
    required this.brand,
  });

  final String text;
  final bool mine;
  final SisBrand brand;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(brand.bubbleRadius),
            gradient: mine ? brand.mineGradient : null,
            color: mine ? null : brand.theirs,
            border: mine ? null : Border.all(color: brand.line),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Text(
              text,
              style: TextStyle(color: mine ? brand.onMine : brand.onTheirs),
            ),
          ),
        ),
      ),
    );
  }
}
