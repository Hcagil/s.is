import 'package:flutter/material.dart';

import 'swipe_back.dart';

/// The Nocturne design: ink violet, the system font (Manrope stays bundled
/// as the switch-off font), rounded but precise shapes.
/// Values are the design tokens in docs/DESIGN.md §10; change them there first.
ThemeData sisTheme(Brightness brightness) {
  final t = brightness == Brightness.dark ? SisBrand.dark : SisBrand.light;
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
  final text = ThemeData(brightness: brightness).textTheme
      .apply(bodyColor: t.text, displayColor: t.text);
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
    required this.unreadEdge,
    required this.prism,
  });

  final Color background, surface, surfaceHigh, text, muted, line;
  final Color brand, brandDeep, theirs, glow, glowDeep, danger, unreadEdge;

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
    unreadEdge: Color(0xFFFFD54F),
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
    unreadEdge: Color(0xFFFFD54F),
    prism: LinearGradient(
      colors: [Color(0xFF4450FF), Color(0xFF8B5CFF), Color(0xFFC45BE6)],
      stops: [0, .55, 1],
    ),
  );

  static SisBrand of(BuildContext context) =>
      Theme.of(context).extension<SisBrand>() ?? light;

  @override
  SisBrand copyWith() => this;

  @override
  SisBrand lerp(SisBrand? other, double t) =>
      other == null ? this : (t < .5 ? this : other);
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
