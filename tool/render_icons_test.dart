// Renders the launcher icon sources from the same painter the app uses, so
// the icon and the in-app logo cannot drift apart. Not part of the test suite
// (it lives outside test/); run it when the logo changes, then regenerate:
//
//   flutter test tool/render_icons_test.dart
//   dart run flutter_launcher_icons
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/brand.dart';

Future<void> _render(SisLogoLayer layer, int px, String path) async {
  final recorder = ui.PictureRecorder();
  SisLogoPainter(layer).paint(Canvas(recorder), Size.square(px.toDouble()));
  final image = await recorder.endRecording().toImage(px, px);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('render launcher icon sources', () async {
    const dir = 'tool/icon';
    await _render(SisLogoLayer.background, 1024, '$dir/background.png');
    await _render(SisLogoLayer.foreground, 1024, '$dir/foreground.png');
    await _render(SisLogoLayer.monochrome, 1024, '$dir/monochrome.png');
    await _render(SisLogoLayer.full, 1024, '$dir/full.png');
    // Google Play's store listing icon: 512 px, full square; Play rounds it.
    await _render(SisLogoLayer.full, 512, '$dir/play-store-512.png');
  });
}
