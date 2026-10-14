import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/appearance_controller.dart';
import '../domain/appearance_settings.dart';
import '../domain/custom_theme.dart';
import 'appearance_labels.dart';

/// Opens the Light or dark card: rises from the bottom over a dimmed screen,
/// each tap applies at once, a tap on the dim area closes it.
Future<void> showAppearanceModeCard(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      elevation: 0,
      builder: (_) => const _ModeCard(),
    );

class _ModeCard extends ConsumerWidget {
  const _ModeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = ref.watch(appearanceProvider);
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Material(
          key: const ValueKey('appearance-mode-card'),
          color: t.surfaceHigh,
          borderRadius: BorderRadius.circular(22),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  child: Text(
                    l.appearanceModeTitle,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                for (final m in AppearanceMode.values)
                  _ModeOption(
                    mode: m,
                    selected: look.mode == m,
                    onTap: () =>
                        ref.read(appearanceProvider.notifier).setMode(m),
                  ),
                const SizedBox(height: 12),
                Container(
                  key: const ValueKey('appearance-mode-note'),
                  margin: const EdgeInsets.fromLTRB(20, 6, 20, 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: t.background,
                    border: Border.all(color: t.line),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _getNoteText(look, l),
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.4,
                      color: t.muted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _getNoteText(AppearanceSettings look, AppLocalizations l) {
    final custom = look.activeCustomTheme;
    if (custom == null) return l.appearanceModeNoteBuiltIn;
    return switch (custom.mode) {
      CustomThemeMode.light => l.appearanceModeNoteAlwaysLight(custom.name),
      CustomThemeMode.dark => l.appearanceModeNoteAlwaysDark(custom.name),
      CustomThemeMode.automatic => l.appearanceModeNoteFollows(custom.name),
    };
  }
}

class _ModeOption extends StatelessWidget {
  const _ModeOption({
    required this.mode,
    required this.selected,
    required this.onTap,
  });

  final AppearanceMode mode;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    final l = AppLocalizations.of(context);

    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        key: ValueKey('appearance-mode-${mode.name}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: [
              _buildTile(t, mode),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      appearanceModeLabel(l, mode),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (mode == AppearanceMode.system)
                      Text(
                        l.appearanceModeFollowHint,
                        style: TextStyle(fontSize: 12.5, color: t.muted),
                      ),
                  ],
                ),
              ),
              _buildRadio(t, selected),
            ],
          ),
        ),
      ),
    );
  }

  static Widget _buildTile(SisBrand t, AppearanceMode mode) {
    return Container(
      width: 44,
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: t.line),
        color: mode == AppearanceMode.system
            ? null
            : mode == AppearanceMode.light
            ? const Color(0xFFF5F4FA)
            : const Color(0xFF0D0B22),
        gradient: mode == AppearanceMode.system
            ? LinearGradient(
                begin: Alignment(-1, -0.3),
                end: Alignment(1, 0.3),
                colors: [
                  const Color(0xFFF5F4FA),
                  const Color(0xFFF5F4FA),
                  const Color(0xFF0D0B22),
                  const Color(0xFF0D0B22),
                ],
                stops: [0, 0.5, 0.5, 1],
              )
            : null,
      ),
      child: Align(
        alignment: const Alignment(-0.45, -0.1),
        child: Container(
          width: 20,
          height: 6,
          decoration: BoxDecoration(
            color: t.brand,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
      ),
    );
  }

  static Widget _buildRadio(SisBrand t, bool selected) {
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: selected ? t.brand : t.muted, width: 2),
      ),
      child: selected
          ? Center(
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: t.brand,
                ),
              ),
            )
          : null,
    );
  }
}
