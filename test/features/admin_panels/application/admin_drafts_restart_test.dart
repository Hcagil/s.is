// test/features/admin_panels/application/admin_drafts_restart_test.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/features/admin_panels/data/secure_admin_draft_store.dart';
import 'package:sis/features/admin_panels/application/admin_drafts.dart';

import '../../../support/secure_channel_fake.dart';

ProviderContainer newApp() {
  final c = ProviderContainer(
    overrides: [
      adminDraftStoreProvider.overrideWithValue(SecureAdminDraftStore()),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('AdminDrafts with SecureAdminDraftStore', () {
    test('a flushed draft survives a restart', () async {
      final kc = SecureChannelFake();
      kc.install();
      final app1 = newApp();
      final d1 = app1.read(adminDraftsProvider);

      await d1.write(adminTalkDraftKey('c1'), 'hello there');
      await d1.write(adminTalkDraftKey(null), 'new box text');
      await d1.write(adminQuestionDraftKey('Q-1'), 'my answer');
      await d1.flush();

      app1.dispose();

      final app2 = newApp();
      final d2 = app2.read(adminDraftsProvider);

      expect(await d2.read(adminTalkDraftKey('c1')), 'hello there');
      expect(await d2.read(adminTalkDraftKey(null)), 'new box text');
      expect(await d2.read(adminQuestionDraftKey('Q-1')), 'my answer');
      expect(await d2.read(adminQuestionDraftKey('Q-2')), '');
    });

    test('only the one secure entry is used', () async {
      final kc = SecureChannelFake();
      kc.install();
      final app = newApp();
      final d = app.read(adminDraftsProvider);

      await d.write(adminTalkDraftKey('c1'), 'hello');
      await d.write(adminTalkDraftKey(null), 'new');
      await d.write(adminQuestionDraftKey('Q-1'), 'ans');
      await d.flush();

      expect(kc.items[null]!.keys, {'sis.admin.drafts'});
      for (final call in kc.calls) {
        if (call.method == 'write') {
          expect(call.key, 'sis.admin.drafts');
        }
      }
    });

    test('the debounce writes to the secure store by itself', () async {
      final kc = SecureChannelFake();
      kc.install();
      final app = newApp();
      final d = app.read(adminDraftsProvider);

      await d.write(adminTalkDraftKey('c1'), 'debounce test');
      await Future.delayed(const Duration(milliseconds: 700));

      final stored = kc.get(null, 'sis.admin.drafts');
      expect(stored, isNotNull);
      expect(stored!.contains('debounce test'), isTrue);
    });

    test('wipe removes the entry', () async {
      final kc = SecureChannelFake();
      kc.install();
      final app = newApp();
      final d = app.read(adminDraftsProvider);

      await d.write(adminTalkDraftKey('c1'), 'to wipe');
      await d.flush();
      await d.wipe();

      expect(kc.get(null, 'sis.admin.drafts'), isNull);

      final app2 = newApp();
      final d2 = app2.read(adminDraftsProvider);
      expect(await d2.read(adminTalkDraftKey('c1')), '');
    });

    test('no draft text is printed or logged', () async {
      final kc = SecureChannelFake();
      kc.install();
      final printed = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (String? m, {int? wrapWidth}) {
        printed.add(m ?? '');
      };
      try {
        await runZoned(
          () async {
            final app = newApp();
            final d = app.read(adminDraftsProvider);
            await d.write(adminTalkDraftKey('c1'), 'secret-ish draft body');
            await d.flush();
            await d.wipe();
          },
          zoneSpecification: ZoneSpecification(
            print: (self, parent, zone, line) {
              printed.add(line);
            },
          ),
        );
      } finally {
        debugPrint = originalDebugPrint;
      }
      for (final line in printed) {
        expect(line.contains('secret-ish draft body'), isFalse);
      }
    });

    test('nothing goes to SharedPreferences', () async {
      final kc = SecureChannelFake();
      kc.install();
      SharedPreferences.setMockInitialValues({});
      final app = newApp();
      final d = app.read(adminDraftsProvider);

      await d.write(adminTalkDraftKey('c1'), 'no prefs');
      await d.flush();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);
    });

    test('cap survives the store', () async {
      final kc = SecureChannelFake();
      kc.install();
      final app = newApp();
      final d = app.read(adminDraftsProvider);

      final long = 'z' * 9000;
      await d.write(adminTalkDraftKey('c1'), long);
      await d.flush();

      final app2 = newApp();
      final d2 = app2.read(adminDraftsProvider);
      final read = await d2.read(adminTalkDraftKey('c1'));
      expect(read.length, adminDraftMax);
    });

    test('a broken keystore never blocks typing', () async {
      final kc = SecureChannelFake();
      kc.install();
      kc.failRead = (_, _) => true;
      final app = newApp();
      final d = app.read(adminDraftsProvider);

      await expectLater(d.write(adminTalkDraftKey('c1'), 'x'), completes);
      await expectLater(d.flush(), completes);
      await expectLater(d.read(adminTalkDraftKey('c1')), completes);
    });
  });
}
