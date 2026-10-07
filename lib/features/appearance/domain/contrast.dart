import 'dart:math' show pow, max, min;

/// WCAG minimum contrast for text.
const double textMinContrast = 4.5;

/// WCAG minimum contrast for a non-text part (an accent against its surface).
const double accentMinContrast = 3.0;

const int _black = 0xFF000000;
const int _white = 0xFFFFFFFF;

/// One sRGB channel (0..255) as linear light.
double _lin(int c8) {
  final c = c8 / 255.0;
  return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();
}

/// WCAG relative luminance, 0 (black) to 1 (white). Alpha is ignored.
double relativeLuminance(int argb) {
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  return 0.2126 * _lin(r) + 0.7152 * _lin(g) + 0.0722 * _lin(b);
}

/// WCAG contrast ratio, 1 to 21: (lighter + 0.05) / (darker + 0.05).
double contrastRatio(int a, int b) {
  final la = relativeLuminance(a);
  final lb = relativeLuminance(b);
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}

/// [preferred] when it reads on [background] at [textMinContrast], else black
/// or white, whichever reads better (always at least 4.58:1).
int readableOn(int background, {required int preferred}) {
  if (contrastRatio(preferred, background) >= textMinContrast) {
    return preferred;
  }
  final black = contrastRatio(_black, background);
  final white = contrastRatio(_white, background);
  return white >= black ? _white : _black;
}

/// White text unless that fails [textMinContrast] on [background]; then black
/// or white, whichever reads better.
int readableOnWhitePreferred(int background) =>
    readableOn(background, preferred: _white);

/// True when [accent] on [surface] is below [accentMinContrast].
bool accentHardToRead(int accent, int surface) =>
    contrastRatio(accent, surface) < accentMinContrast;
