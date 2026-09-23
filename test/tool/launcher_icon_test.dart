// The launcher icon ships as resources the build only packages; nothing at
// runtime would notice one missing, so these files are checked directly.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

const res = 'android/app/src/main/res';

/// Width and height from a PNG's IHDR chunk, or null when not a PNG.
(int, int)? pngSize(String path) {
  final b = File(path).readAsBytesSync();
  const sig = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  if (b.length < 24) return null;
  for (var i = 0; i < 8; i++) {
    if (b[i] != sig[i]) return null;
  }
  final d = ByteData.sublistView(b);
  return (d.getUint32(16), d.getUint32(20));
}

void main() {
  test('the adaptive icon has background, foreground and monochrome layers, '
      'each resolving to a resource that exists', () {
    final xml = File('$res/mipmap-anydpi-v26/ic_launcher.xml')
        .readAsStringSync();
    expect(xml, contains('<adaptive-icon'));
    for (final layer in ['background', 'foreground', 'monochrome']) {
      final element = RegExp(
        '<$layer\\b.*?(/>|</$layer>)',
        dotAll: true,
      ).firstMatch(xml);
      expect(element, isNotNull, reason: 'no <$layer> layer');
      final m = RegExp(
        'android:drawable="@(drawable|mipmap|color)/([a-z0-9_]+)"',
      ).firstMatch(element![0]!);
      expect(m, isNotNull, reason: '<$layer> names no drawable');
      final (type, name) = (m!.group(1)!, m.group(2)!);
      if (type == 'color') continue;
      final found = Directory(res)
          .listSync()
          .whereType<Directory>()
          .where((d) => d.path.split('/').last.startsWith(type))
          .any(
            (d) => d.listSync().any(
              (f) => f.path.split('/').last.split('.').first == name,
            ),
          );
      expect(found, isTrue, reason: '@$type/$name is referenced but missing');
    }
  });

  const densities = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  for (final MapEntry(key: density, value: px) in densities.entries) {
    test('mipmap-$density/ic_launcher.png is a ${px}px PNG', () {
      expect(pngSize('$res/mipmap-$density/ic_launcher.png'), (px, px));
    });
  }

  test('the manifest points at the launcher icon', () {
    expect(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
      contains('android:icon="@mipmap/ic_launcher"'),
    );
  });

  test('the Play Store icon is 512x512', () {
    expect(pngSize('tool/icon/play-store-512.png'), (512, 512));
  });
}
