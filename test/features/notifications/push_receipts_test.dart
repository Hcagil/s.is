// Push receipts: what the phone records about every push its background
// handler sees, and the fix they were added with.
//
// The production defect (2026-09-25 .. 09-29): on release builds
// flutter_local_notifications' cancelAll() threw (R8 had stripped Gson's
// TypeToken), LocalPushDisplay.forUser stored the inbox owner only AFTER it,
// so no owner was ever written and every push was dropped as "no owner".
// The shade below throws from cancelAll exactly as the release plugin did.
//
// Device fakes (test/support/push_platform.dart) plus, here, the parts of a
// device that are inconvenient: a plugin whose calls throw, a preferences
// file that cannot be read, notifications switched off in Android settings.
//
// Run under TZ=JST-9 (as CI does): occurred_at crosses to the server.
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/notifications/data/firebase_push_source.dart';
import 'package:sis/features/notifications/data/local_push_display.dart';
import 'package:sis/features/notifications/data/push_receipt_log.dart';

import '../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _receiptsKey = 'flutter.sis.push_receipts';

/// Words a push carries that must never be recorded in a receipt.
const _title = 'Zelda Secretname';
const _body = 'the confidential body text';
const _chat = 'c-private-chat';
const _msg = '6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d';

const _terminal = {
  'shown',
  'error',
  'dropped:has_notification',
  'dropped:missing_fields',
  'dropped:no_owner',
  'dropped:owner_mismatch',
  'dropped:notifications_off',
  'dropped:not_drawn',
};

RemoteMessage _push({
  String? to,
  bool notification = false,
  Map<String, dynamic>? data,
}) => RemoteMessage(
  notification: notification
      ? const RemoteNotification(title: _title, body: _body)
      : null,
  data:
      data ??
      {
        'conversation_id': _chat,
        'title': _title,
        'body': _body,
        'message_id': _msg,
        'user_id': ?to,
      },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late DiskPrefs disk;

  /// What the notifications plugin answers besides the shade's own calls.
  bool? enabled;
  Object? cancelAllThrows;
  Object? enabledThrows;

  void newIsolate() => SharedPreferences.resetStatic();

  Future<Object?> plugin(MethodCall call) async {
    switch (call.method) {
      case 'areNotificationsEnabled' when enabledThrows != null:
        shade.calls.add(call.method);
        throw enabledThrows!;
      case 'areNotificationsEnabled':
        return enabled;
      case 'cancelAll' when cancelAllThrows != null:
        shade.calls.add(call.method);
        throw cancelAllThrows!;
    }
    return shade.handle(call);
  }

  Future<List<Map<String, Object?>>> receipts() async {
    newIsolate();
    return PushReceiptLog.pending();
  }

  Future<List<Object?>> stages() async => [
    for (final r in await receipts()) r['stage'],
  ];

  /// A push arriving: Android's native receiver (the only drawer since
  /// Update 1) at once, then the background handler in its own isolate, as
  /// FCM runs it. The handler itself never draws on Android.
  Future<void> background(RemoteMessage m) async {
    NativeReceiver(shade, disk)
      ..notificationsOn = enabled != false
      ..receive(m.data, notification: m.notification != null);
    newIsolate();
    final mark = shade.calls.length;
    await onBackgroundPush(m);
    expect(
      shade.calls.sublist(mark),
      isNot(contains('show')),
      reason: 'the Dart handler drew on Android',
    );
  }

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shade = Shade();
    disk = DiskPrefs();
    enabled = null;
    cancelAllThrows = null;
    enabledThrows = null;
    messenger.setMockMethodCallHandler(Shade.channel, plugin);
    messenger.setMockMethodCallHandler(_prefsChannel, disk.handle);
    newIsolate();
    await LocalPushDisplay.init();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(Shade.channel, null);
    messenger.setMockMethodCallHandler(_prefsChannel, null);
  });

  // Runs first on purpose: PackageInfo caches a successful answer for the
  // process, so the "no build number" case must come before any mock.
  group('PushReceiptLog', () {
    test(
      'a receipt with no PackageInfo has no build, and the rest of it',
      () async {
        await PushReceiptLog.add('received', messageId: _msg);

        final r = (await receipts()).single;
        expect(r['stage'], 'received');
        expect(r['message_id'], _msg);
        expect(r.containsKey('build'), isFalse, reason: '$r');
        expect(r.containsKey('error'), isFalse, reason: '$r');
      },
    );

    test('carries the build number as an integer', () async {
      PackageInfo.setMockInitialValues(
        appName: 'SIS',
        packageName: 'com.esd.sis',
        version: '0.30.0',
        buildNumber: '4711',
        buildSignature: '',
      );
      await PushReceiptLog.add('shown');

      expect((await receipts()).single['build'], 4711);
    });

    test('occurred_at is now, written with its offset so the server reads '
        'the same instant', () async {
      final before = DateTime.now();
      await PushReceiptLog.add('shown');
      final after = DateTime.now();

      final raw = (await receipts()).single['occurred_at']! as String;
      expect(
        raw,
        matches(RegExp(r'(Z|[+-]\d\d:?\d\d)$')),
        reason: 'no offset: the server would read local time as UTC',
      );
      final at = DateTime.parse(raw);
      expect(at.isBefore(before.subtract(const Duration(seconds: 1))), isFalse);
      expect(at.isAfter(after.add(const Duration(seconds: 1))), isFalse);
    });

    test('keeps entries in the order they happened, across isolates', () async {
      await PushReceiptLog.add('received', messageId: 'a');
      newIsolate();
      await PushReceiptLog.add('shown', messageId: 'a');
      newIsolate();
      await PushReceiptLog.add('received', messageId: 'b');

      expect(
        [for (final r in await receipts()) '${r['stage']}/${r['message_id']}'],
        ['received/a', 'shown/a', 'received/b'],
      );
    });

    test('keeps only the newest 50', () async {
      for (var i = 0; i < 55; i++) {
        await PushReceiptLog.add('received', messageId: 'm$i');
      }

      final ids = [for (final r in await receipts()) r['message_id']];
      expect(ids, [for (var i = 5; i < 55; i++) 'm$i']);
    });

    // Contract (security review of #76): an error is recorded by its runtime
    // type only. Exception text can quote a push or a device path; a receipt
    // leaves the phone.
    test('an error is its type only, never its text', () async {
      await PushReceiptLog.add('error', error: StateError('secret ' * 200));

      final e = (await receipts()).single['error'];
      expect(e, 'StateError');
    });

    test('a PlatformException is its type only', () async {
      await PushReceiptLog.add(
        'error',
        error: PlatformException(code: 'error', message: _body),
      );

      final r = (await receipts()).single;
      expect(r['error'], 'PlatformException');
      expect(jsonEncode(r), isNot(contains('confidential')));
    });

    test('a FormatException is recorded by type only: its text can quote '
        'the push', () async {
      await PushReceiptLog.add(
        'error',
        error: const FormatException('Unexpected', _body, 3),
      );

      final r = (await receipts()).single;
      expect(r['error'], 'FormatException');
      expect(jsonEncode(r), isNot(contains('confidential')));
    });

    test('pending skips a corrupt entry and keeps the good ones', () async {
      await PushReceiptLog.add('received', messageId: 'good1');
      await PushReceiptLog.add('shown', messageId: 'good2');
      final stored = (disk.values[_receiptsKey]! as List).cast<String>();
      disk.values[_receiptsKey] = [stored[0], '{not json', '[1,2]', stored[1]];

      expect(
        [for (final r in await receipts()) r['message_id']],
        ['good1', 'good2'],
      );
    });

    test('pending is empty when there is nothing', () async {
      expect(await receipts(), isEmpty);
    });

    test('removeFirst drops the oldest entries only', () async {
      for (final id in ['a', 'b', 'c', 'd']) {
        await PushReceiptLog.add('received', messageId: id);
      }
      newIsolate();
      await PushReceiptLog.removeFirst(3);

      expect([for (final r in await receipts()) r['message_id']], ['d']);
    });

    test(
      'removeFirst beyond the length empties it; 0 keeps everything',
      () async {
        await PushReceiptLog.add('received', messageId: 'a');
        await PushReceiptLog.removeFirst(0);
        expect(await receipts(), hasLength(1));

        await PushReceiptLog.removeFirst(10);
        expect(await receipts(), isEmpty);
      },
    );

    test('a key holding something else: pending is [], add and removeFirst '
        'do not throw', () async {
      disk.values[_receiptsKey] = 'not a list';

      await expectLater(PushReceiptLog.add('received'), completes);
      await expectLater(PushReceiptLog.removeFirst(1), completes);
      expect(await receipts(), isEmpty);
    });

    test('a preferences file that cannot be read: nothing throws', () async {
      messenger.setMockMethodCallHandler(_prefsChannel, (call) async {
        throw PlatformException(code: 'io', message: 'disk gone');
      });
      newIsolate();

      await expectLater(PushReceiptLog.add('received'), completes);
      await expectLater(PushReceiptLog.removeFirst(1), completes);
      newIsolate();
      expect(await PushReceiptLog.pending(), isEmpty);
    });
  });

  group('onBackgroundPush: received, then exactly one terminal receipt', () {
    test('shown: an owner, addressed to them', () async {
      await LocalPushDisplay.forUser('member-a');
      final mark = (await receipts()).length;

      await background(_push(to: 'member-a'));

      expect((await stages()).sublist(mark), ['received', 'shown']);
      expect(shade.childChats, {_chat});
    });

    test('shown: an owner, a push without user_id (older server)', () async {
      await LocalPushDisplay.forUser('member-a');
      final mark = (await receipts()).length;

      await background(_push());

      expect((await stages()).sublist(mark), ['received', 'shown']);
      expect(shade.childChats, {_chat});
    });

    test('shown: the note is still ",q" (the receiver is drawing it) when '
        'the handler runs', () async {
      await LocalPushDisplay.forUser('member-a');
      final mark = (await receipts()).length;
      disk.values['flutter.sis.push_arrival.$_msg'] = '1700000000123,?,?,q';

      newIsolate();
      await onBackgroundPush(_push(to: 'member-a'));

      final after = (await receipts()).sublist(mark);
      expect([for (final r in after) r['stage']], ['received', 'shown']);
      expect(after.first['error'], contains('fast=native'));
    });

    test('dropped:not_drawn: ours, but the receiver settled its note '
        'without ",n"', () async {
      await LocalPushDisplay.forUser('member-a');
      final mark = (await receipts()).length;
      disk.values['flutter.sis.push_arrival.$_msg'] = '1700000000123,?,?';

      newIsolate();
      await onBackgroundPush(_push(to: 'member-a'));

      final after = (await receipts()).sublist(mark);
      expect(
        [for (final r in after) r['stage']],
        ['received', 'dropped:not_drawn'],
      );
      expect(after.first['error'], isNot(contains('fast=')));
    });

    for (final (name, id) in [
      ('no message id', null),
      ('a message id that is not a UUID', 'not-a-uuid'),
    ]) {
      test('dropped:not_drawn: $name, which the receiver does not '
          'draw', () async {
        await LocalPushDisplay.forUser('member-a');
        final mark = (await receipts()).length;

        await background(
          _push(
            data: {
              'conversation_id': _chat,
              'title': _title,
              'body': _body,
              'message_id': ?id,
              'user_id': 'member-a',
            },
          ),
        );

        expect((await stages()).sublist(mark), [
          'received',
          'dropped:not_drawn',
        ]);
        expect(shade.posted, isEmpty);
      });
    }

    test('dropped:has_notification: Android drew it itself', () async {
      await LocalPushDisplay.forUser('member-a');
      final mark = (await receipts()).length;

      await background(_push(to: 'member-a', notification: true));

      expect((await stages()).sublist(mark), [
        'received',
        'dropped:has_notification',
      ]);
      expect(shade.posted, isEmpty);
    });

    for (final field in ['conversation_id', 'title', 'body']) {
      for (final bad in <Object?>[null, 7]) {
        test(
          'dropped:missing_fields: $field ${bad == null ? 'absent' : 'not '
                    'a string'}',
          () async {
            await LocalPushDisplay.forUser('member-a');
            final mark = (await receipts()).length;
            final data = <String, dynamic>{
              'conversation_id': _chat,
              'title': _title,
              'body': _body,
              'message_id': _msg,
            };
            if (bad == null) {
              data.remove(field);
            } else {
              data[field] = bad;
            }

            await background(_push(data: data));

            expect((await stages()).sublist(mark), [
              'received',
              'dropped:missing_fields',
            ]);
            expect(shade.posted, isEmpty);
          },
        );
      }
    }

    test('dropped:no_owner: nobody signed in on this phone', () async {
      await background(_push(to: 'member-a'));

      expect(await stages(), ['received', 'dropped:no_owner']);
      expect(shade.posted, isEmpty);
      expect(jsonEncode(disk.values), isNot(contains('confidential')));
    });

    test('dropped:owner_mismatch: addressed to someone else', () async {
      await LocalPushDisplay.forUser('member-a');
      final mark = (await receipts()).length;

      await background(_push(to: 'member-b'));

      expect((await stages()).sublist(mark), [
        'received',
        'dropped:owner_mismatch',
      ]);
      expect(shade.posted, isEmpty);
    });

    test(
      'dropped:notifications_off: switched off in Android settings',
      () async {
        await LocalPushDisplay.forUser('member-a');
        final mark = (await receipts()).length;
        enabled = false;

        await background(_push(to: 'member-a'));

        expect((await stages()).sublist(mark), [
          'received',
          'dropped:notifications_off',
        ]);
        expect(shade.posted, isEmpty);
      },
    );

    test('error: a platform call throws; the handler does not', () async {
      await LocalPushDisplay.forUser('member-a');
      final mark = (await receipts()).length;
      enabledThrows = PlatformException(code: 'error', message: 'plugin broke');

      await expectLater(background(_push(to: 'member-a')), completes);

      final after = (await receipts()).sublist(mark);
      expect([for (final r in after) r['stage']], ['received', 'error']);
      expect(after.last['error'], isA<String>());
      expect(after.last['error'], isNotEmpty);
      expect(after.last['error'], isNot(contains('plugin broke')));
    });

    group('the order of the checks', () {
      test('has_notification before missing_fields', () async {
        await background(
          _push(notification: true, data: {'conversation_id': _chat}),
        );
        expect(await stages(), ['received', 'dropped:has_notification']);
      });

      test('missing_fields before no_owner', () async {
        await background(_push(data: {'conversation_id': _chat}));
        expect(await stages(), ['received', 'dropped:missing_fields']);
      });

      test('owner_mismatch before notifications_off', () async {
        await LocalPushDisplay.forUser('member-a');
        final mark = (await receipts()).length;
        enabled = false;

        await background(_push(to: 'member-b'));

        expect((await stages()).sublist(mark), [
          'received',
          'dropped:owner_mismatch',
        ]);
      });
    });

    test('every path: received first, exactly one terminal, the message id '
        'on both, and no text of the push in any receipt', () async {
      final paths = <String, Future<void> Function()>{
        'no_owner': () => background(_push(to: 'member-a')),
        'has_notification': () async {
          await LocalPushDisplay.forUser('member-a');
          await background(_push(to: 'member-a', notification: true));
        },
        'missing_fields': () => background(
          _push(
            data: {
              'conversation_id': _chat,
              'title': _title,
              'message_id': _msg,
            },
          ),
        ),
        'owner_mismatch': () => background(_push(to: 'member-b')),
        'notifications_off': () async {
          enabled = false;
          await background(_push(to: 'member-a'));
          enabled = null;
        },
        'shown': () => background(_push(to: 'member-a')),
        'not_drawn': () async {
          // Ours and allowed, but the native receiver did not draw it (it
          // was not there, or failed): no fast=native note.
          newIsolate();
          await onBackgroundPush(_push(to: 'member-a'));
        },
        'error': () async {
          // A plugin error that quotes the push.
          enabledThrows = PlatformException(code: 'error', message: _body);
          await background(_push(to: 'member-a'));
          enabledThrows = null;
        },
      };

      final everything = StringBuffer();
      for (final MapEntry(key: name, value: run) in paths.entries) {
        newIsolate();
        await PushReceiptLog.removeFirst(1000);
        // Each path is a first delivery: a line already in the inbox for
        // this message id is a redelivery, which (correctly) draws nothing.
        disk.values.removeWhere(
          (k, _) => k.startsWith('flutter.sis.push_inbox.'),
        );
        await run();
        final after = await receipts();
        everything.write(jsonEncode(after));
        final s = [for (final r in after) r['stage']];
        // forUser's own receipts (none expected) would be before 'received'.
        final from = s.indexOf('received');
        expect(from, isNot(-1), reason: '$name: $s');
        final handler = after.sublist(from);
        expect(handler, hasLength(2), reason: '$name: $s');
        expect(_terminal, contains(handler[1]['stage']), reason: '$name: $s');
        expect(handler[1]['stage'], anyOf(name, 'dropped:$name'));
        for (final r in handler) {
          expect(r['message_id'], _msg, reason: '$name: $r');
        }
      }

      for (final s in [_title, 'Zelda', _body, 'confidential', _chat]) {
        expect('$everything', isNot(contains(s)), reason: '$everything');
      }
    });

    test('a Doze backlog handled at once: every push the receiver drew gets '
        'exactly one shown', () async {
      await LocalPushDisplay.forUser('member-a');
      newIsolate(); // FCM's background isolate
      await PushReceiptLog.removeFirst(1000);
      final ids = [
        for (var i = 0; i < 6; i++) '0000000$i-2a55-4c1f-9e0a-0d7f7b1a2c3d',
      ];

      final pushes = [
        for (var i = 0; i < ids.length; i++)
          _push(
            to: 'member-a',
            data: {
              'conversation_id': 'c-${i % 3}',
              'title': 'Sender $i',
              'body': 'burst line $i',
              'message_id': ids[i],
              'user_id': 'member-a',
            },
          ),
      ];
      for (final m in pushes) {
        NativeReceiver(shade, disk).receive(m.data);
      }
      await Future.wait([for (final m in pushes) onBackgroundPush(m)]);

      final all = await receipts();
      for (final id in ids) {
        final mine = [
          for (final r in all)
            if (r['message_id'] == id) r['stage'],
        ];
        expect(mine, ['received', 'shown'], reason: '$id: $all');
      }
      for (var i = 0; i < ids.length; i++) {
        expect(
          Shade.text(shade.childFor('c-${i % 3}')),
          contains('burst line $i'),
        );
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a message_id that is not a string is left out', () async {
      await background(
        _push(
          data: {
            'conversation_id': _chat,
            'title': _title,
            'body': _body,
            'message_id': 42,
          },
        ),
      );

      for (final r in await receipts()) {
        expect(r.containsKey('message_id'), isFalse, reason: '$r');
      }
    });

    test('a preferences file that cannot be read: the handler still does '
        'not throw', () async {
      messenger.setMockMethodCallHandler(_prefsChannel, (call) async {
        throw PlatformException(code: 'io', message: 'disk gone');
      });

      await expectLater(background(_push(to: 'member-a')), completes);
    });
  });

  group('LocalPushDisplay', () {
    group('forUser when cancelAll throws (the release-build defect)', () {
      setUp(() {
        cancelAllThrows = PlatformException(
          code: 'error',
          message: 'Missing type parameter.',
        );
      });

      test('the owner is still stored, and the next push is shown', () async {
        await expectLater(LocalPushDisplay.forUser('member-a'), completes);
        expect(shade.calls, contains('cancelAll'), reason: 'precondition');

        newIsolate();
        expect(await LocalPushDisplay.currentOwner(), 'member-a');
        expect(disk.values['flutter.sis.push_inbox_owner'], 'member-a');

        await background(_push(to: 'member-a'));
        expect(shade.childChats, {_chat});
        expect((await stages()).last, 'shown');
      });

      test('the failure is recorded as an error receipt', () async {
        await LocalPushDisplay.forUser('member-a');

        final errors = [
          for (final r in await receipts())
            if (r['stage'] == 'error') r['error'],
        ];
        expect(errors, hasLength(1));
        expect(errors.single, startsWith('forUser cancelAll:'));
        expect(
          errors.single,
          isNot(contains('Missing type parameter')),
          reason: 'a fixed label and the type, never the exception text',
        );
      });

      test('forUser(null) still removes the owner', () async {
        cancelAllThrows = null;
        await LocalPushDisplay.forUser('member-a');
        cancelAllThrows = PlatformException(code: 'error');

        await expectLater(LocalPushDisplay.forUser(null), completes);

        newIsolate();
        expect(await LocalPushDisplay.currentOwner(), isNull);
        await background(_push(to: 'member-a'));
        expect(shade.posted, isEmpty);
        expect((await stages()).last, 'dropped:no_owner');
      });
    });

    group('a change of owner clears the receipts', () {
      // Receipts are uploaded as whoever is signed in: one member's must
      // never be uploaded under the next member's account.
      Future<void> collectedBy(String owner) async {
        await LocalPushDisplay.forUser(owner);
        await background(_push(to: owner));
        expect(await stages(), contains('shown'), reason: 'precondition');
      }

      test('to another member', () async {
        await collectedBy('member-a');
        await LocalPushDisplay.forUser('member-b');
        expect(await receipts(), isEmpty);
      });

      test('to nobody (signed out)', () async {
        await collectedBy('member-a');
        await LocalPushDisplay.forUser(null);
        expect(await receipts(), isEmpty);
      });

      test('the same member again keeps them', () async {
        await collectedBy('member-a');
        newIsolate();
        await LocalPushDisplay.forUser('member-a');
        expect(await stages(), ['received', 'shown']);
      });
    });

    test('a working cancelAll leaves no error receipt', () async {
      await LocalPushDisplay.forUser('member-a');
      expect(await receipts(), isEmpty);
    });

    test('notificationsEnabled(): the plugin\'s answer, true when it has '
        'none', () async {
      enabled = false;
      expect(await LocalPushDisplay.notificationsEnabled(), isFalse);
      enabled = true;
      expect(await LocalPushDisplay.notificationsEnabled(), isTrue);
      enabled = null;
      expect(await LocalPushDisplay.notificationsEnabled(), isTrue);
    });
  });
}
