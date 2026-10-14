import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import '../domain/sticker_maker.dart';
import './u2net_tensors.dart';

/// Bundled U2-NetP model run by ONNX Runtime on the phone; the fallback when
/// the platform cut-out is unavailable. Fully offline.
final class OnnxStickerCutter implements StickerCutter {
  static const modelAsset = 'assets/models/u2netp.onnx';

  Future<OrtSession>? _session;

  Future<OrtSession> _open() =>
      _session ??= OnnxRuntime().createSessionFromAsset(modelAsset);

  @override
  Future<bool> supported() async {
    try {
      await _open();
      return true;
    } on Object {
      _session = null;
      return false;
    }
  }

  @override
  Future<Uint8List?> mask(Uint8List jpeg) async {
    OrtValue? input;
    Map<String, OrtValue>? outputs;
    ui.Codec? codec;
    ui.Image? image;
    try {
      final session = await _open();
      codec = await ui.instantiateImageCodec(
        jpeg,
        targetWidth: u2netSide,
        targetHeight: u2netSide,
      );
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      input = await OrtValue.fromList(
        u2netInput(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        ),
        [1, 3, u2netSide, u2netSide],
      );
      outputs = await session.run({'input': input});
      final d0 = outputs['d0'];
      if (d0 == null) return null;
      final probs = (await d0.asFlattenedList())
          .map((e) => (e as num).toDouble())
          .toList();
      return u2netMask(probs);
    } on Object {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      await input?.dispose();
      for (final output in outputs?.values ?? const <OrtValue>[]) {
        await output.dispose();
      }
    }
  }
}
