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

  test('every placeholder of an EN message is used in its TR message', () {
    final meta = jsonDecode(
      File('lib/l10n/app_en.arb').readAsStringSync(),
    ) as Map<String, Object?>;
    for (final key in en.keys) {
      final m = meta['@$key'] as Map<String, Object?>?;
      final ph = (m?['placeholders'] as Map<String, Object?>?)?.keys ?? [];
      for (final name in ph) {
        expect(
          tr[key] as String,
          contains('{$name'),
          reason: 'tr $key drops {$name}',
        );
      }
    }
  });
}
