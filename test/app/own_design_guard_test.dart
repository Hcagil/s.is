// Everything visible is SIS's own design: no Android-drawn UI in lib/.
// A cheap source scan, so a SnackBar, a stock spinner, switch or radio, the
// stock licence page or the system photo picker cannot creep back in
// unnoticed. Comments are ignored (the replacements' docs name what they
// replace); SisProgressLine may build on LinearProgressIndicator inside
// lib/app/loading.dart, and nowhere else.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

final banned = <String, RegExp>{
  'SnackBar': RegExp(r'\bSnackBar\b|showSnackBar'),
  'ScaffoldMessenger': RegExp(r'\bScaffoldMessenger\b'),
  'CircularProgressIndicator': RegExp(r'\bCircularProgressIndicator\b'),
  'RefreshProgressIndicator': RegExp(r'\bRefreshProgressIndicator\b'),
  'CupertinoActivityIndicator': RegExp(r'\bCupertinoActivityIndicator\b'),
  'LinearProgressIndicator': RegExp(r'\bLinearProgressIndicator\b'),
  'Switch': RegExp(r'\bSwitch(\.adaptive)?\s*\(|\bSwitchListTile\b'),
  'Radio': RegExp(r'\bRadio(ListTile|Group)?\b\s*[<(]'),
  'stock licence page': RegExp(r'\bshowLicensePage\b|\bLicensePage\s*\('),
  'stock about dialog': RegExp(r'\bshowAboutDialog\b|\bAboutDialog\s*\('),
  'image_picker': RegExp(r'image_picker|\bImagePicker\b'),
};

/// Where a banned name is the thing being built, not a use of it.
const allowed = {'LinearProgressIndicator': 'lib/app/loading.dart'};

/// [source] without `//` comments (doc comments included).
String code(String source) => source
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

void main() {
  final files =
      Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  test('there is a lib/ to scan', () => expect(files.length, greaterThan(20)));

  for (final MapEntry(key: name, value: pattern) in banned.entries) {
    test('lib/ uses no $name', () {
      final hits = [
        for (final f in files)
          if (allowed[name] != f.path.replaceAll(r'\', '/'))
            for (final (i, line) in code(
              f.readAsStringSync(),
            ).split('\n').indexed)
              if (pattern.hasMatch(line)) '${f.path}:${i + 1}: ${line.trim()}',
      ];
      expect(hits, isEmpty, reason: 'Android-drawn UI is not SIS\'s design');
    });
  }

  // 2026-09-28: "From an app" hands the choice to another app through
  // Android's app chooser. That is the member's own gallery, not an
  // Android-drawn picker: the native side must list apps, never open the
  // system photo picker.
  test('the native side never opens Android\'s photo picker', () {
    final systemPicker = RegExp(
      r'ACTION_PICK_IMAGES|PickVisualMedia|PickMultipleVisualMedia|'
      r'photopicker|image_picker|ImagePicker',
    );
    final native = Directory('android/app/src/main')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.kt') || f.path.endsWith('.java'))
        .toList();
    expect(native, isNotEmpty, reason: 'no native code found to scan');
    final hits = [
      for (final f in native)
        for (final (i, line) in code(f.readAsStringSync()).split('\n').indexed)
          if (systemPicker.hasMatch(line)) '${f.path}:${i + 1}: ${line.trim()}',
    ];
    expect(hits, isEmpty, reason: 'the system photo picker is not SIS\'s');
  });

  test('image_picker is not a dependency any more', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      isNot(contains('image_picker')),
    );
  });
}
