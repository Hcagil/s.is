// The licences page over the REAL registry: the Flutter/Dart package licences
// the build bundles (NOTICES.Z) plus the font licences main.dart adds. Every
// package any entry names must be listed, and none twice.
//
// The test binding deliberately registers no NOTICES collector, although
// `flutter test` does bundle NOTICES.Z. So this file registers it the way the
// production ServicesBinding.initLicenses does: gunzip, split on the 80-dash
// separator, package names are the lines before the first blank line.
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/licences_page.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/main.dart' as entry;

/// Mirrors ServicesBinding._parseLicenses (flutter/services/binding.dart).
Stream<LicenseEntry> _notices() async* {
  final bytes = await rootBundle.load('NOTICES.Z');
  final raw = utf8.decode(gzip.decode(bytes.buffer.asUint8List()));
  for (final licence in raw.split('\n${'-' * 80}\n')) {
    final split = licence.indexOf('\n\n');
    yield split >= 0
        ? LicenseEntryWithLineBreaks(
            licence.substring(0, split).split('\n'),
            licence.substring(split + 2),
          )
        : LicenseEntryWithLineBreaks(const [], licence);
  }
}

void main() {
  testWidgets('every bundled package is listed exactly once', (t) async {
    LicenseRegistry.reset();
    addTearDown(LicenseRegistry.reset);
    LicenseRegistry.addLicense(_notices);
    // main() reads the stored appearance before runApp.
    SharedPreferences.setMockInitialValues({});
    // main() without dart-defines registers the fonts, then mounts the
    // "Setup required" app, which is swapped out below.
    await t.pumpWidget(const SizedBox());
    await entry.main();
    await t.pumpWidget(const SizedBox());

    final entries = (await t.runAsync(
      () => LicenseRegistry.licenses.toList(),
    ))!;
    final packages = {for (final e in entries) ...e.packages};
    // ignore: avoid_print
    print(
      'real registry: ${entries.length} entries, ${packages.length} packages',
    );
    expect(packages, containsAll(['flutter', 'manrope', 'sora']));

    // Tall enough that the lazy list builds every tile at once.
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = Size(800, 120.0 * packages.length + 400);
    addTearDown(t.view.reset);

    await t.pumpWidget(
      MaterialApp(
        theme: sisTheme(Brightness.light),
        home: const SisLicencesPage(
          applicationName: 'SIS',
          applicationVersion: '1.0.0',
        ),
      ),
    );
    for (var i = 0; i < 200 && find.text('sora').evaluate().isEmpty; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }
    await t.pumpAndSettle();

    final missing = [
      for (final p in packages)
        if (find.text(p).evaluate().isEmpty) p,
    ];
    final twice = [
      for (final p in packages)
        if (find.text(p).evaluate().length > 1) p,
    ];
    expect(missing, isEmpty, reason: 'packages with no tile');
    expect(twice, isEmpty, reason: 'packages with more than one tile');

    // Every multi-entry package carries its count; the counts add up.
    final many = [
      for (final p in packages)
        if (entries.where((e) => e.packages.contains(p)).length case final n
            when n > 1)
          n,
    ];
    final labels = find
        .textContaining(RegExp(r'^\d+ licences$'))
        .evaluate()
        .map((e) => int.parse((e.widget as Text).data!.split(' ').first));
    // ignore: avoid_print
    print(
      'multi-entry packages: ${many.length}, entries among them: '
      '${many.fold(0, (a, b) => a + b)}',
    );
    expect(labels.length, many.length);
    expect(labels.fold(0, (a, b) => a + b), many.fold(0, (a, b) => a + b));
  });
}
