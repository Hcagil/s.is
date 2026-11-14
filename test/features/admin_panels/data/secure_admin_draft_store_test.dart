import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/data/secure_admin_draft_store.dart';

import '../../../support/secure_channel_fake.dart';

void main() {
  late SecureChannelFake kc;

  setUp(() {
    kc = SecureChannelFake();
    kc.install();
  });

  group('SecureAdminDraftStore', () {
    test('1 nothing stored', () async {
      final store = SecureAdminDraftStore();
      expect(await store.load(), isEmpty);
    });

    test('2 save and load roundtrip', () async {
      final store = SecureAdminDraftStore();
      await store.save({'q:a': 'hello', 'talk:new': 'x'});
      final newStore = SecureAdminDraftStore();
      final loaded = await newStore.load();
      expect(loaded, {'q:a': 'hello', 'talk:new': 'x'});
      expect(kc.items[null]!.keys, {'sis.admin.drafts'});
      final json = jsonDecode(kc.items[null]!['sis.admin.drafts']!);
      expect(json, {
        'v': 1,
        'd': {'q:a': 'hello', 'talk:new': 'x'},
      });
    });

    test('3 empty save deletes entry', () async {
      final store = SecureAdminDraftStore();
      await store.save({'a': 'b'});
      await store.save({});
      expect(kc.get(null, 'sis.admin.drafts'), isNull);
      expect(await store.load(), isEmpty);
    });

    test('4 clear removes entry', () async {
      final store = SecureAdminDraftStore();
      await store.save({'a': 'b'});
      await store.clear();
      expect(kc.get(null, 'sis.admin.drafts'), isNull);
      expect(await store.load(), isEmpty);
    });

    test('5 corrupt values', () async {
      final store = SecureAdminDraftStore();
      // not json
      kc.put(null, 'sis.admin.drafts', 'not json');
      expect(await store.load(), isEmpty);
      // wrong version
      kc.put(
        null,
        'sis.admin.drafts',
        jsonEncode({
          'v': 2,
          'd': {'a': 'b'},
        }),
      );
      expect(await store.load(), isEmpty);
      // wrong type
      kc.put(null, 'sis.admin.drafts', jsonEncode([1]));
      expect(await store.load(), isEmpty);
      // non-string values
      kc.put(
        null,
        'sis.admin.drafts',
        jsonEncode({
          'v': 1,
          'd': {'a': 'b', 'c': 5},
        }),
      );
      expect(await store.load(), {'a': 'b'});
    });

    test('6 read error handled', () async {
      final store = SecureAdminDraftStore();
      kc.put(
        null,
        'sis.admin.drafts',
        jsonEncode({
          'v': 1,
          'd': {'a': 'b'},
        }),
      );
      kc.failRead = (_, _) => true;
      expect(await store.load(), isEmpty);
      expect(kc.changes, isEmpty);
    });

    test('7a android options: resetOnError false', () async {
      final store = SecureAdminDraftStore();
      await store.save({'a': 'b'});
      await store.load();
      await store.clear();
      final methods = kc.calls.map((c) => c.method).toList();
      expect(methods, containsAll(['write', 'read', 'delete']));
      for (final call in kc.calls) {
        expect(call.options['resetOnError'], 'false');
      }
    });

    test('7b ios options: first_unlock_this_device', () async {
      final kc = SecureChannelFake();
      kc.install(platform: TargetPlatform.iOS);
      final store = SecureAdminDraftStore();
      await store.save({'a': 'b'});
      await store.load();
      await store.clear();
      final methods = kc.calls.map((c) => c.method).toList();
      expect(methods, containsAll(['write', 'read', 'delete']));
      for (final call in kc.calls) {
        expect(call.options['accessibility'], 'first_unlock_this_device');
      }
    });

    test('8 unicode long text roundtrip', () async {
      final long = 'é' * 8192;
      final store = SecureAdminDraftStore();
      await store.save({'long': long});
      final loaded = await store.load();
      expect(loaded['long'], long);
    });

    test('9 only one key written', () async {
      final store = SecureAdminDraftStore();
      await store.save({'a': '1'});
      await store.save({'b': '2'});
      await store.save({'c': '3'});
      final writeCalls = kc.calls.where((c) => c.method == 'write').toList();
      for (final call in writeCalls) {
        expect(call.key, 'sis.admin.drafts');
      }
    });
  });
}
