// The licences page must credit SQLite3 Multiple Ciphers, the encryption
// library of the on-phone message store: main() registers its licence text
// from assets/licenses/SQLITE3-MULTIPLE-CIPHERS-LICENSE.txt.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/main.dart' as entry;

void main() {
  testWidgets('main() registers the SQLite3 Multiple Ciphers licence', (
    t,
  ) async {
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(const SizedBox());
    await entry.main();
    await t.pumpWidget(const SizedBox());

    final entries = (await t.runAsync(
      () => LicenseRegistry.licenses.toList(),
    ))!;
    final mc = entries
        .where((e) => e.packages.contains('SQLite3 Multiple Ciphers'))
        .toList();
    expect(mc, hasLength(1));
    final text = mc.single.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('MIT'));
    expect(text.length, greaterThan(500));
  });
}
