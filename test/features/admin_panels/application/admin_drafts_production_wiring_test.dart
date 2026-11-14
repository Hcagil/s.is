// test/features/admin_panels/application/admin_drafts_production_wiring_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

List<File> libFiles() =>
    Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList();

void main() {
  final mainText = read('lib/main.dart');

  test('main.dart overrides the draft store with SecureAdminDraftStore', () {
    expect(
      mainText,
      contains(
        'adminDraftStoreProvider.overrideWithValue(SecureAdminDraftStore())',
      ),
    );
  });

  test(
    'the override is in the same provider scope as the other admin stores',
    () {
      final a = mainText.indexOf('adminDraftStoreProvider.overrideWithValue');
      final b = mainText.indexOf('adminSnapshotStoreProvider.overrideWith(');
      expect(a, greaterThanOrEqualTo(0));
      expect(b, greaterThanOrEqualTo(0));
      expect((a - b).abs(), lessThan(1500));
    },
  );

  test('main.dart never uses the memory store', () {
    expect(mainText, isNot(contains('MemoryAdminDraftStore')));
  });

  test('only the provider default uses the memory store', () {
    final memoryFiles = libFiles()
        .where((f) => f.readAsStringSync().contains('MemoryAdminDraftStore('))
        .map((f) => f.path)
        .toSet();
    expect(memoryFiles, {
      'lib/features/admin_panels/application/admin_drafts.dart',
    });
  });

  test('SecureAdminDraftStore( is constructed only in main.dart', () {
    final secureFiles = libFiles()
        .where((f) => f.readAsStringSync().contains('SecureAdminDraftStore('))
        .map((f) => f.path)
        .toSet();
    expect(secureFiles, {
      'lib/main.dart',
      'lib/features/admin_panels/data/secure_admin_draft_store.dart',
    });
    expect(secureFiles.contains('lib/main.dart'), isTrue);
  });
}
