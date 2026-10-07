import 'package:flutter/material.dart';

import '../features/appearance/domain/appearance_settings.dart';
import '../features/appearance/domain/custom_theme.dart';
import 'swipe_back.dart';

/// The Nocturne design: ink violet, the system font (Manrope stays bundled
/// as the switch-off font), rounded but precise shapes.
/// Values are the design tokens in docs/DESIGN.md §10; change them there first.
///
/// [theme] picks one of the six palettes; [systemFont] false uses Manrope.
/// [brand] replaces the palette (a custom theme).
ThemeData sisTheme(
  Brightness brightness, {
  AppThemeId theme = AppThemeId.violet,
  bool systemFont = true,
  SisBrand? brand,
}) {
  final t = brand ?? sisBrandFor(theme, brightness);
  // null: the phone's own font; off, SIS's bundled Manrope.
  final family = systemFont ? null : 'Manrope';
  final scheme = ColorScheme(
    brightness: brightness,
    primary: t.brand,
    onPrimary: Colors.white,
    primaryContainer: t.surfaceHigh,
    onPrimaryContainer: t.text,
    secondary: t.brandDeep,
    onSecondary: Colors.white,
    tertiary: t.prism.colors.last,
    onTertiary: Colors.white,
    error: t.danger,
    onError: Colors.white,
    surface: t.background,
    onSurface: t.text,
    onSurfaceVariant: t.muted,
    surfaceContainerLowest: t.surface,
    surfaceContainerLow: t.surface,
    surfaceContainer: t.surface,
    surfaceContainerHigh: t.surfaceHigh,
    surfaceContainerHighest: t.surfaceHigh,
    outline: t.line,
    outlineVariant: t.line,
  );
  const r8 = BorderRadius.all(Radius.circular(8));
  const r12 = BorderRadius.all(Radius.circular(12));
  const r16 = BorderRadius.all(Radius.circular(16));
  final text = ThemeData(
    brightness: brightness,
    fontFamily: family,
  ).textTheme.apply(bodyColor: t.text, displayColor: t.text);
  // Filled buttons carry the brand gradient; disabled ones fall back to the
  // theme's flat disabled colour.
  Widget gradient(BuildContext _, Set<WidgetState> states, Widget? child) =>
      DecoratedBox(
        decoration: BoxDecoration(
          gradient: states.contains(WidgetState.disabled) ? null : t.gradient,
          borderRadius: r12,
        ),
        child: child,
      );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: family,
    colorScheme: scheme,
    textTheme: text.copyWith(
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    ),
    scaffoldBackgroundColor: t.background,
    // Every page slides in the iOS way on both platforms and leaves with a
    // right drag that can start anywhere on it (see swipe_back.dart): the
    // Android system gesture owns both screen edges, so an edge-only swipe
    // never fires there.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: SwipeBackTransitionsBuilder(),
        TargetPlatform.iOS: SwipeBackTransitionsBuilder(),
      },
    ),
    extensions: [t],
    appBarTheme: AppBarTheme(
      backgroundColor: t.background,
      foregroundColor: t.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
    ),
    dividerTheme: DividerThemeData(color: t.line, thickness: 1, space: 1),
    filledButtonTheme: FilledButtonThemeData(
      style:
          FilledButton.styleFrom(
            minimumSize: const Size(64, 50),
            shape: const RoundedRectangleBorder(borderRadius: r12),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
            ),
          ).copyWith(
            backgroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.disabled)
                  ? t.surfaceHigh
                  : Colors.transparent,
            ),
            backgroundBuilder: gradient,
          ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 50),
        foregroundColor: t.text,
        side: BorderSide(color: t.line),
        shape: const RoundedRectangleBorder(borderRadius: r12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: r12),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: const RoundedRectangleBorder(borderRadius: r12),
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: t.brand,
      foregroundColor: Colors.white,
      elevation: 2,
      shape: const RoundedRectangleBorder(borderRadius: r16),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: t.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: r8,
        borderSide: BorderSide(color: t.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: r8,
        borderSide: BorderSide(color: t.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: r8,
        borderSide: BorderSide(color: t.brand, width: 1.5),
      ),
      hintStyle: text.bodyLarge?.copyWith(color: t.muted),
    ),
    cardTheme: CardThemeData(
      color: t.surface,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: r12,
        side: BorderSide(color: t.line),
      ),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: t.muted,
      subtitleTextStyle: text.bodyMedium?.copyWith(
        color: t.muted,
        fontSize: 14,
      ),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? Colors.white : t.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.brand : t.surfaceHigh,
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const CircleBorder(),
      fillColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? t.brand : null,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: t.background,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: t.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: r16),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: t.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: r12,
        side: BorderSide(color: t.line),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: t.brand),
  );
}

/// Brand colours that Material's ColorScheme has no slot for: the two
/// gradients, the conversation glow, and the other side's bubble.
@immutable
class SisBrand extends ThemeExtension<SisBrand> {
  const SisBrand({
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.text,
    required this.muted,
    required this.line,
    required this.brand,
    required this.brandDeep,
    required this.theirs,
    required this.glow,
    required this.glowDeep,
    required this.danger,
    required this.prism,
    this.mine,
  });

  final Color background, surface, surfaceHigh, text, muted, line;
  final Color brand, brandDeep, theirs, glow, glowDeep, danger;

  /// My bubble colour of a custom theme; null: the brand colours' gradient.
  final Color? mine;

  /// Corner radius of a chat bubble (slice 5 uses it).
  final double bubbleRadius = 16;

  /// Three stops, used only on the logo and the "SIS" wordmark.
  final LinearGradient prism;

  /// Two stops, on your own bubbles and filled buttons.
  LinearGradient get gradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [brandDeep, brand],
  );

  /// S10, a row separator that fades out at both ends.
  LinearGradient get fadingSeparator =>
      LinearGradient(colors: [line.withAlpha(0), line, line.withAlpha(0)]);

  /// White's luminance (1.0) plus the 0.05 WCAG offset.
  static const _whiteContrastBase = 1.05;

  /// [c] darkened toward black until white text on it reaches [min]:1
  /// (WCAG contrast); unchanged when it already does.
  static Color forWhiteText(Color c, {double min = 4.5}) {
    var out = c;
    for (
      var i = 0;
      i < 30 && _whiteContrastBase / (out.computeLuminance() + 0.05) < min;
      i++
    ) {
      out = Color.lerp(out, const Color(0xFF000000), .06)!;
    }
    return out;
  }

  /// [gradient] for your own message bubbles: both ends darkened just enough
  /// that white message text reads at 4.5:1 or better in every theme and
  /// brightness (a blend of two such colours is darker still, so the whole
  /// bubble passes).
  LinearGradient get mineGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: mine == null
        ? [forWhiteText(brandDeep), forWhiteText(brand)]
        : [forWhiteText(mine!), forWhiteText(mine!)],
  );

  /// S3, the soft-edged unread pill.
  LinearGradient get unreadPillFade => LinearGradient(
    colors: [
      brand.withValues(alpha: .5),
      brand.withValues(alpha: .8),
      brand.withValues(alpha: .5),
    ],
  );

  static const light = SisBrand(
    background: Color(0xFFF5F4FA),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFECEBF5),
    text: Color(0xFF13112B),
    muted: Color(0xFF65627F),
    line: Color(0xFFDEDCEB),
    brand: Color(0xFF5B4CF0),
    brandDeep: Color(0xFF2F3FD1),
    theirs: Color(0xFFFFFFFF),
    glow: Color(0x295B4CF0),
    glowDeep: Color(0x1A2F3FD1),
    danger: Color(0xFFD23F57),
    prism: LinearGradient(
      colors: [Color(0xFF2E36D9), Color(0xFF6D35E8), Color(0xFFB23FD0)],
      stops: [0, .55, 1],
    ),
  );

  static const dark = SisBrand(
    background: Color(0xFF0D0B22),
    surface: Color(0xFF151334),
    surfaceHigh: Color(0xFF1D1A42),
    text: Color(0xFFECEAFB),
    muted: Color(0xFF9A96C0),
    line: Color(0xFF25224B),
    brand: Color(0xFF7B6BFF),
    brandDeep: Color(0xFF3D4BE8),
    theirs: Color(0xFF1D1A42),
    glow: Color(0x3D7B6BFF),
    glowDeep: Color(0x293D4BE8),
    danger: Color(0xFFFF7B8E),
    prism: LinearGradient(
      colors: [Color(0xFF4450FF), Color(0xFF8B5CFF), Color(0xFFC45BE6)],
      stops: [0, .55, 1],
    ),
  );

  static SisBrand of(BuildContext context) =>
      Theme.of(context).extension<SisBrand>() ?? light;

  @override
  SisBrand copyWith({
    Color? background,
    Color? surface,
    Color? surfaceHigh,
    Color? text,
    Color? muted,
    Color? line,
    Color? brand,
    Color? brandDeep,
    Color? theirs,
    Color? glow,
    Color? glowDeep,
    Color? danger,
    LinearGradient? prism,
    Color? mine,
  }) => SisBrand(
    background: background ?? this.background,
    surface: surface ?? this.surface,
    surfaceHigh: surfaceHigh ?? this.surfaceHigh,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    line: line ?? this.line,
    brand: brand ?? this.brand,
    brandDeep: brandDeep ?? this.brandDeep,
    theirs: theirs ?? this.theirs,
    glow: glow ?? this.glow,
    glowDeep: glowDeep ?? this.glowDeep,
    danger: danger ?? this.danger,
    prism: prism ?? this.prism,
    mine: mine ?? this.mine,
  );

  @override
  SisBrand lerp(SisBrand? other, double t) =>
      other == null ? this : (t < .5 ? this : other);
}

/// The phone's text scale times the member's app text size. A phone that
/// scales text non-linearly is read at its 1.0 step (ponytail: exact for
/// linear scalers, the common case).
TextScaler sisTextScaler(TextScaler system, double factor) =>
    factor == 1 ? system : TextScaler.linear(system.scale(1) * factor);

/// One theme's colours for one brightness, as 0xRRGGBB:
/// background, surface, surfaceHigh, line, text, muted, brand, brandDeep.
/// Contrast was checked for all twelve: text 15:1+, muted 4.9:1+ on every
/// surface, white on brandDeep 4.2:1+, white on brand 3.0:1+, brand on
/// background 3.6:1+.
typedef _Tone = (int, int, int, int, int, int, int, int);

const Map<AppThemeId, (_Tone light, _Tone dark)> _tones = {
  AppThemeId.ocean: (
    (
      0xF2F7FC,
      0xFFFFFF,
      0xE3EEF8,
      0xD3E2F0,
      0x0E1B2B,
      0x52677D,
      0x1B7FD1,
      0x1B4FB8,
    ),
    (
      0x0A1626,
      0x0F2236,
      0x163350,
      0x1C3F63,
      0xE6F3FF,
      0x8FB0CC,
      0x2793DB,
      0x1F5FD6,
    ),
  ),
  AppThemeId.forest: (
    (
      0xF1F8F4,
      0xFFFFFF,
      0xE1EFE7,
      0xCFE3D7,
      0x0E2018,
      0x4F6B5C,
      0x2E8F5F,
      0x1B6B49,
    ),
    (
      0x0A1A14,
      0x0F2A20,
      0x163A2C,
      0x1D4A39,
      0xE6F7EE,
      0x8FBBA6,
      0x33A06C,
      0x1E7A55,
    ),
  ),
  AppThemeId.sunset: (
    (
      0xFDF4F1,
      0xFFFFFF,
      0xF8E6E0,
      0xEFD5CC,
      0x2A1220,
      0x7A5560,
      0xD9562B,
      0xC23558,
    ),
    (
      0x1C0C1E,
      0x2A1530,
      0x3A1C40,
      0x4A2650,
      0xFBEAF0,
      0xC79AB5,
      0xEE6736,
      0xC93D62,
    ),
  ),
  AppThemeId.graphite: (
    (
      0xF4F5F7,
      0xFFFFFF,
      0xE8EAEE,
      0xD9DCE2,
      0x15171B,
      0x5A6270,
      0x5A6678,
      0x3A4658,
    ),
    (
      0x15171B,
      0x1E2126,
      0x282C33,
      0x343942,
      0xECEEF2,
      0x9AA3B2,
      0x7B8596,
      0x4A5568,
    ),
  ),
  AppThemeId.rose: (
    (
      0xFCF3F7,
      0xFFFFFF,
      0xF6E4EC,
      0xEDD3DF,
      0x2A0F1C,
      0x7D5468,
      0xD81B60,
      0xAD1457,
    ),
    (
      0x1A0A14,
      0x2A1220,
      0x3A182C,
      0x4C2238,
      0xFBE8F1,
      0xC99AB3,
      0xE8457F,
      0xAD1457,
    ),
  ),
};

/// The brand colours of [id] in [brightness]. Violet is [SisBrand.light] /
/// [SisBrand.dark]; the others keep its logo prism, danger and unread colours.
SisBrand sisBrandFor(AppThemeId id, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = dark ? SisBrand.dark : SisBrand.light;
  final tones = _tones[id];
  if (tones == null) return base;
  final (bg, surface, high, line, text, muted, brand, deep) = dark
      ? tones.$2
      : tones.$1;
  Color c(int rgb) => Color(0xFF000000 | rgb);
  return base.copyWith(
    background: c(bg),
    surface: c(surface),
    surfaceHigh: c(high),
    line: c(line),
    text: c(text),
    muted: c(muted),
    brand: c(brand),
    brandDeep: c(deep),
    theirs: dark ? c(high) : c(surface),
    glow: Color(brand | (dark ? 0x3D000000 : 0x29000000)),
    glowDeep: Color(deep | (dark ? 0x29000000 : 0x1A000000)),
  );
}

/// The brand colours of a custom theme in [brightness]: the Violet surfaces of
/// that brightness with the theme's accent, bubbles and a deeper accent.
SisBrand sisBrandForCustom(CustomTheme custom, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = dark ? SisBrand.dark : SisBrand.light;
  final brand = Color(custom.accent);
  final deep = Color.lerp(brand, const Color(0xFF000000), .25)!;
  return base.copyWith(
    brand: brand,
    brandDeep: deep,
    theirs: Color(custom.theirs),
    mine: Color(custom.mine),
    glow: brand.withAlpha(dark ? 0x3D : 0x29),
    glowDeep: deep.withAlpha(dark ? 0x29 : 0x1A),
  );
}

/// Shared design tokens from the Update 1 mockup (S2..S9). Defined here and
/// wired into screens by later slices.
abstract final class SisTokens {
  /// S2: margin between the reaction chips and the time.
  static const chipToTimeGap = 2.0;

  /// S5: the message time.
  static const timeFontSize = 10.5;
  static const timeOpacity = 0.8;

  /// S6: extra letter-spacing on sender names.
  static const nameLetterSpacing = 0.3;

  /// S7: settings rows.
  static const settingsRowPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 10,
  );
  static const settingsRowRadius = 17.0;

  /// S8: section labels.
  static const sectionLabelWeight = FontWeight.w600;

  /// S9: a 2% white sheen across the top of confirmation buttons.
  static const sheenOpacity = 0.02;
  static const sheenHeightFraction = 0.02;

  /// Delivery tick (option A): soft at rest, a 0.3 s fade on change.
  static const tickRestOpacity = 0.75;
  static const tickReadOpacity = 0.95;
  static const tickFade = Duration(milliseconds: 300);
  static const tickReadColor = Color(0xFF8FF0FF);

  /// GreyOption: the disabled look.
  static const greyOpacity = 0.4;
}
