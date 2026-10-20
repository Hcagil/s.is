// UiPhotoCropRenderer on real pixels (the dart:ui engine in the test
// runner), written from PhotoCropRenderer's contract: turn [turns] quarter
// turns anticlockwise, cut the fractions of the TURNED photo, return a PNG at
// crop size, scaled down only when the longest side is over 2048, same
// photoGroup; null when the bytes are not a photo.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/ui_photo_crop_renderer.dart';
import 'package:sis/features/chat/domain/attachment.dart';

const red = Color(0xFFFF0000);
const green = Color(0xFF00FF00);
const blue = Color(0xFF0000FF);
const white = Color(0xFFFFFFFF);

/// A [w]x[h] PNG in four quadrants: red top-left, green top-right, blue
/// bottom-left, white bottom-right.
Future<PickedImage> quadrants(int w, int h, {String? group}) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  final hw = w / 2, hh = h / 2;
  c.drawRect(Rect.fromLTWH(0, 0, hw, hh), Paint()..color = red);
  c.drawRect(Rect.fromLTWH(hw, 0, hw, hh), Paint()..color = green);
  c.drawRect(Rect.fromLTWH(0, hh, hw, hh), Paint()..color = blue);
  c.drawRect(Rect.fromLTWH(hw, hh, hw, hh), Paint()..color = white);
  final img = await rec.endRecording().toImage(w, h);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  return PickedImage(
    bytes: png!.buffer.asUint8List(),
    contentType: 'image/png',
    extension: 'png',
    photoGroup: group,
  );
}

class Decoded {
  Decoded(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final ByteData rgba;

  Color at(int x, int y) {
    final i = (y * width + x) * 4;
    return Color.fromARGB(
      rgba.getUint8(i + 3),
      rgba.getUint8(i),
      rgba.getUint8(i + 1),
      rgba.getUint8(i + 2),
    );
  }
}

Future<Decoded> decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final img = (await codec.getNextFrame()).image;
  final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final d = Decoded(img.width, img.height, data!);
  img.dispose();
  return d;
}

Future<Decoded> cut(
  PickedImage src, {
  int turns = 0,
  double left = 0,
  double top = 0,
  double right = 1,
  double bottom = 1,
}) async {
  final out = await const UiPhotoCropRenderer().render(
    src,
    turns: turns,
    left: left,
    top: top,
    right: right,
    bottom: bottom,
  );
  expect(out, isNotNull);
  expect(out!.contentType, 'image/png');
  expect(out.bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47], reason: 'PNG');
  expect(out.photoGroup, src.photoGroup);
  return decode(out.bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'no turn, whole photo: same size and the four colours in place',
    () async {
      final d = await cut(await quadrants(40, 20, group: 'g1'));
      expect((d.width, d.height), (40, 20));
      expect(d.at(5, 5), red);
      expect(d.at(35, 5), green);
      expect(d.at(5, 15), blue);
      expect(d.at(35, 15), white);
    },
  );

  test('a cut of the top-right quarter is 20x10, all green', () async {
    final d = await cut(await quadrants(40, 20), left: .5, bottom: .5);
    expect((d.width, d.height), (20, 10));
    for (final p in [(1, 1), (18, 1), (1, 8), (18, 8), (10, 5)]) {
      expect(d.at(p.$1, p.$2), green, reason: 'at $p');
    }
  });

  test('one anticlockwise turn: 20x40, green top-left, white top-right, '
      'red bottom-left, blue bottom-right', () async {
    final d = await cut(await quadrants(40, 20), turns: 1);
    expect((d.width, d.height), (20, 40));
    expect(d.at(5, 5), green);
    expect(d.at(15, 5), white);
    expect(d.at(5, 35), red);
    expect(d.at(15, 35), blue);
  });

  test('turn then cut: fractions are of the TURNED photo', () async {
    // Turned photo is 20x40; its top half is green (left) and white (right).
    final d = await cut(
      await quadrants(40, 20),
      turns: 1,
      left: .5,
      bottom: .5,
    );
    expect((d.width, d.height), (10, 20));
    for (final p in [(1, 1), (8, 1), (1, 18), (8, 18)]) {
      expect(d.at(p.$1, p.$2), white, reason: 'at $p');
    }
  });

  test('three turns is one clockwise turn', () async {
    final d = await cut(await quadrants(40, 20), turns: 3);
    expect((d.width, d.height), (20, 40));
    expect(d.at(5, 5), blue);
    expect(d.at(15, 5), red);
    expect(d.at(5, 35), white);
    expect(d.at(15, 35), green);
  });

  test('above 2048 the longest side is scaled down to 2048', () async {
    final d = await cut(await quadrants(3000, 1000));
    expect(d.width, 2048);
    expect(d.height, closeTo(683, 1));
    expect(d.at(100, 100), red);
    expect(d.at(2000, 600), white);
  });

  test('at or below 2048 nothing is scaled', () async {
    final d = await cut(await quadrants(2048, 100));
    expect((d.width, d.height), (2048, 100));
    final e = await cut(await quadrants(2000, 1000), left: .25, right: .75);
    expect((e.width, e.height), (1000, 1000));
  });

  test('garbage bytes give null, never throw', () async {
    final out = await const UiPhotoCropRenderer().render(
      PickedImage(
        bytes: Uint8List.fromList(List<int>.generate(64, (i) => i * 7)),
        contentType: 'image/png',
        extension: 'png',
      ),
      turns: 0,
      left: 0,
      top: 0,
      right: 1,
      bottom: 1,
    );
    expect(out, isNull);
  });
}
