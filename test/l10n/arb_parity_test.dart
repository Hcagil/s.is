import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Message keys of an ARB file: metadata (`@…`, `@@locale`) left out.
Map<String, Object?> messages(String path) {
  final all = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
  return {
    for (final e in all.entries)
      if (!e.key.startsWith('@')) e.key: e.value,
  };
}

void main() {
  final en = messages('lib/l10n/app_en.arb');
  final tr = messages('lib/l10n/app_tr.arb');

  test('EN and TR have the same keys', () {
    expect(en, isNotEmpty);
    expect(tr.keys.toSet(), en.keys.toSet());
  });

  test('no message is empty', () {
    for (final (name, arb) in [('en', en), ('tr', tr)]) {
      for (final e in arb.entries) {
        expect(e.value, isA<String>(), reason: '$name ${e.key}');
        expect(
          (e.value! as String).trim(),
          isNotEmpty,
          reason: '$name ${e.key} is empty',
        );
      }
    }
  });
}
