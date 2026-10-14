import 'dart:typed_data';

import '../domain/sticker_maker.dart';

const int u2netSide = 320;

/// Converts RGBA bytes to normalized CHW tensor for U2Net input.
Float32List u2netInput(Uint8List rgba) {
  if (rgba.length != u2netSide * u2netSide * 4) {
    throw ArgumentError(
      'RGBA length must be ${u2netSide * u2netSide * 4}, got ${rgba.length}',
    );
  }

  final Float32List result = Float32List(3 * u2netSide * u2netSide);
  const List<double> mean = [0.485, 0.456, 0.406];
  const List<double> std = [0.229, 0.224, 0.225];

  for (int c = 0; c < 3; c++) {
    for (int y = 0; y < u2netSide; y++) {
      for (int x = 0; x < u2netSide; x++) {
        final int pixelIdx = (y * u2netSide + x) * 4;
        final double v = rgba[pixelIdx + c] / 255.0;
        final int idx = c * u2netSide * u2netSide + y * u2netSide + x;
        result[idx] = (v - mean[c]) / std[c];
      }
    }
  }

  return result;
}

/// Converts U2Net output probabilities to a mask for sticker size.
Uint8List? u2netMask(List<double> probs) {
  if (probs.length != u2netSide * u2netSide) return null;

  double min = probs[0];
  double max = probs[0];
  for (final double p in probs) {
    if (p < min) min = p;
    if (p > max) max = p;
  }

  final double range = max - min;
  if (range < 0.05) return null;

  final List<double> normalized = probs.map((p) => (p - min) / range).toList();

  final Uint8List mask = Uint8List(stickerSide * stickerSide);
  final double scale = (u2netSide - 1) / (stickerSide - 1);

  bool any = false;
  for (int y = 0; y < stickerSide; y++) {
    for (int x = 0; x < stickerSide; x++) {
      final double srcX = x * scale;
      final double srcY = y * scale;

      final int x0 = srcX.toInt();
      final int y0 = srcY.toInt();
      final int x1 = (x0 + 1).clamp(0, u2netSide - 1);
      final int y1 = (y0 + 1).clamp(0, u2netSide - 1);

      final double fx = srcX - x0;
      final double fy = srcY - y0;

      final double p00 = normalized[y0 * u2netSide + x0];
      final double p01 = normalized[y0 * u2netSide + x1];
      final double p10 = normalized[y1 * u2netSide + x0];
      final double p11 = normalized[y1 * u2netSide + x1];

      final double p =
          p00 * (1 - fx) * (1 - fy) +
          p01 * fx * (1 - fy) +
          p10 * (1 - fx) * fy +
          p11 * fx * fy;

      final int byte = (p * 255).round().clamp(0, 255);
      mask[y * stickerSide + x] = byte;
      if (byte > 25) any = true;
    }
  }

  if (!any) return null;
  return mask;
}
