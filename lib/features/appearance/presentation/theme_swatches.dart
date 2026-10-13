import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';

/// A scrolling row of colour swatches; the picked one is ringed. Colours are
/// ARGB ints.
class ThemeSwatchRow extends StatelessWidget {
  const ThemeSwatchRow({
    super.key,
    required this.group,
    required this.colours,
    required this.selected,
    required this.onPick,
  });

  /// Key prefix of the swatches, e.g. `accent`.
  final String group;
  final List<int> colours;
  final int? selected;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    final l = AppLocalizations.of(context);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          spacing: 8,
          children: [
            for (final c in colours)
              Semantics(
                button: true,
                selected: c == selected,
                label: l.themeSwatch(_hex(c)),
                child: InkWell(
                  key: ValueKey('swatch-$group-${_hex(c)}'),
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => onPick(c),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Color(c),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: c == selected ? t.brand : t.line,
                        width: 2,
                      ),
                      boxShadow: c == selected
                          ? [BoxShadow(color: t.glow, spreadRadius: 2)]
                          : null,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  static String _hex(int c) =>
      (c & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
}
