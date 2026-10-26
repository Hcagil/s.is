// The licences page credits every Rust crate in the native lib: main()
// registers assets/licenses/RUST-LICENSES.txt, read only when the registry is
// consumed (the licence page opens), never at registration.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/app/rust_licences.dart';
import 'package:sis/main.dart' as entry;

const _mustCredit = ['vodozemac', 'matrix-pickle', 'dart-sys'];

String _text(LicenseEntry e) => e.paragraphs.map((p) => p.text).join('\n');

void _expectCredited(List<LicenseEntry> entries) {
  for (final crate in _mustCredit) {
    final hits = entries.where((e) => e.packages.contains(crate)).toList();
    expect(hits, isNotEmpty, reason: 'no licence registered for $crate');
    for (final e in hits) {
      expect(_text(e).trim(), isNotEmpty, reason: crate);
    }
  }
}

void main() {
  setUp(() {
    LicenseRegistry.reset();
    rootBundle.evict(rustLicencesAsset);
  });
  tearDown(LicenseRegistry.reset);

  testWidgets('registering reads nothing; the asset is read on consumption', (
    t,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var reads = 0;
    // A real asset bundle answer, served off disk, counted per request.
    messenger.setMockMessageHandler('flutter/assets', (message) async {
      final key = Uri.decodeFull(
        utf8.decode(
          message!.buffer.asUint8List(
            message.offsetInBytes,
            message.lengthInBytes,
          ),
        ),
      );
      if (key == rustLicencesAsset) reads++;
      final file = File(key);
      if (!file.existsSync()) return null;
      return ByteData.sublistView(file.readAsBytesSync());
    });
    addTearDown(() => messenger.setMockMessageHandler('flutter/assets', null));

    registerRustLicences();
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(reads, 0, reason: 'registration must do no IO');

    final entries = (await t.runAsync(
      () => LicenseRegistry.licenses.toList(),
    ))!;
    expect(reads, greaterThan(0));
    _expectCredited(entries);
  });

  testWidgets('main() registers the Rust crate licences from the real asset', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(const SizedBox());
    await entry.main();
    await t.pumpWidget(const SizedBox());

    final entries = (await t.runAsync(
      () => LicenseRegistry.licenses.toList(),
    ))!;
    _expectCredited(entries);
  });

  test('every block of the real asset has crate names and text', () {
    final raw = File(rustLicencesAsset).readAsStringSync();
    final blocks = '\n$raw\n'.split('\n@@@@\n').length;
    final entries = parseRustLicences(raw).toList();
    expect(entries, hasLength(blocks));
    expect(entries.length, greaterThan(50));
    final version = RegExp(r'^\d+\.\d+');
    for (final e in entries) {
      final names = e.packages.toList();
      expect(names, isNotEmpty);
      for (final n in names) {
        expect(n, isNot(contains(' ')), reason: 'version left in "$n"');
        expect(n, isNot(matches(version)), reason: n);
        expect(n, isNotEmpty);
      }
      expect(_text(e).trim(), isNotEmpty, reason: names.join(', '));
    }
    _expectCredited(entries);
  });
}
