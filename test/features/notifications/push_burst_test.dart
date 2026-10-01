// 0.30.4: push bursts, arrival timing receipts, sender pictures, and the
// iPhone's read-clears. Written from the 0.30.4 contract, not the code.
//
// The device fakes (test/support/push_platform.dart) plus, here:
// - path_provider's platform side, pointing at two real temp directories,
//   so the real chat list snapshot store and the real avatar cache are the
//   collaborators NotificationAvatars reads -- or throwing, as it does when
//   the platform side is not there.
// - the Android native receiver (PushArrivalReceiver.kt), which cannot run
//   here: its write is reproduced exactly as it lands in the preferences
//   file -- key "flutter.sis.push_arrival.<id>", value "ms,delivered,original"
//   -- and written UNDER a live isolate's cached copy, as a native write is.
// - the iPhone's 'sis/notifications' channel (AppDelegate.swift), which
//   cannot run here either: the Dart side is pinned to the method name and a
//   plain String argument, the only shape the Swift handler accepts.
//
// Real time on purpose: the timing IS the behaviour.
// Run under TZ=JST-9 (as CI does): receipts carry epoch ms and timestamps.
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/data/file_attachment_cache.dart';
import 'package:sis/features/chat/data/file_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/notifications/data/firebase_push_source.dart';
import 'package:sis/features/notifications/data/local_push_display.dart';
import 'package:sis/features/notifications/data/notification_avatars.dart';
import 'package:sis/features/notifications/data/push_receipt_log.dart';

import '../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _iosChannel = MethodChannel('sis/notifications');

/// The exact key the Kotlin receiver writes, as the Dart side sees the
/// FlutterSharedPreferences file: the plugin's "flutter." prefix included.
String _arrivalKey(String id) => 'flutter.sis.push_arrival.$id';

const _msg = '6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d';
const _title = 'Zelda Secretname';
const _body = 'the confidential body text';
const _chat = 'c-private-chat';

final _ava = Uint8List.fromList(List.generate(64, (i) => i));
final _team = Uint8List.fromList(List.generate(64, (i) => 255 - i));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late DiskPrefs disk;
  late Directory support;
  late Directory cache;
  Object? showThrows;
  Object? pathThrows;

  void newIsolate() => SharedPreferences.resetStatic();

  Future<Object?> plugin(MethodCall call) async {
    if (call.method == 'show' && showThrows != null) {
      shade.calls.add(call.method);
      throw showThrows!;
    }
    return shade.handle(call);
  }

  Future<Object?> paths(MethodCall call) async {
    if (pathThrows != null) throw pathThrows!;
    return switch (call.method) {
      'getApplicationSupportDirectory' => support.path,
      'getApplicationCacheDirectory' => cache.path,
      _ => throw MissingPluginException(call.method),
    };
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
    showThrows = null;
    pathThrows = null;
    support = await Directory.systemTemp.createTemp('sis-support-');
    cache = await Directory.systemTemp.createTemp('sis-cache-');
    messenger.setMockMethodCallHandler(Shade.channel, plugin);
    messenger.setMockMethodCallHandler(_prefsChannel, disk.handle);
    messenger.setMockMethodCallHandler(_pathChannel, paths);
    newIsolate();
    await LocalPushDisplay.init();
    await LocalPushDisplay.forUser('member-a');
  });

  tearDown(() async {
    // Idle again before the next test: a flush still pacing its posts
    // finishes, and the next test starts on a quiet phone.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(Shade.channel, null);
    messenger.setMockMethodCallHandler(_prefsChannel, null);
    messenger.setMockMethodCallHandler(_pathChannel, null);
    messenger.setMockMethodCallHandler(_iosChannel, null);
    await support.delete(recursive: true);
    await cache.delete(recursive: true);
  });

  Future<bool> push(String chat, String title, String body) =>
      LocalPushDisplay.show(conversationId: chat, title: title, body: body);

  List<int> gapsSince(int mark) {
    final t = [for (final s in shade.shows.sublist(mark)) s.at];
    return [
      for (var i = 1; i < t.length; i++)
        t[i].difference(t[i - 1]).inMilliseconds,
    ];
  }

  group('pacing', () {
    test('an idle phone posts at once: no fixed wait before the first '
        'post', () async {
      final mark = shade.shows.length;
      final start = DateTime.now();

      expect(await push('c1', 'Ava', 'hello'), isTrue);

      final first = shade.shows[mark].at.difference(start);
      expect(
        first,
        lessThan(const Duration(milliseconds: 250)),
        reason: 'waited ${first.inMilliseconds} ms on an idle phone',
      );
    });

    test('idle again a while after a flush: the next push posts at once '
        'too', () async {
      await push('c1', 'Ava', 'one');
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      final mark = shade.shows.length;
      final start = DateTime.now();

      expect(await push('c2', 'Ben', 'two'), isTrue);

      final first = shade.shows[mark].at.difference(start);
      expect(first, lessThan(const Duration(milliseconds: 250)));
    });

    test('every plugin post is at least 300 ms after the previous one, chat '
        'posts and summary alike, within and across flushes', () async {
      final mark = shade.shows.length;

      final a = [for (var i = 1; i <= 4; i++) push('a$i', 'A$i', 'wave-a-$i')];
      expect(await Future.wait(a), everyElement(isTrue));
      // A second flush right on the heels of the first one's last post.
      final b = [for (var i = 1; i <= 3; i++) push('b$i', 'B$i', 'wave-b-$i')];
      expect(await Future.wait(b), everyElement(isTrue));

      final gaps = gapsSince(mark);
      expect(gaps.length, greaterThanOrEqualTo(6), reason: '$gaps');
      // 5 ms of slack for the clock read in the fake, nothing more.
      expect(gaps, everyElement(greaterThanOrEqualTo(295)), reason: '$gaps');
      expect(shade.peakPostsPerSecond, lessThanOrEqualTo(4), reason: '$gaps');
      for (var i = 1; i <= 4; i++) {
        expect(Shade.text(shade.childFor('a$i')), contains('wave-a-$i'));
      }
      for (var i = 1; i <= 3; i++) {
        expect(Shade.text(shade.childFor('b$i')), contains('wave-b-$i'));
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('an owner change while a flush is posting: show() is true only for '
      'a line that is on screen', () {
    const secrets = ['secret-1', 'secret-2', 'secret-3', 'secret-4'];

    Future<void> inTheAppIsolate(String? member) async {
      final before = Map<String, Object>.of(disk.values);
      newIsolate();
      await LocalPushDisplay.forUser(member);
      final after = Map<String, Object>.of(disk.values);
      disk.values = before;
      newIsolate();
      await SharedPreferences.getInstance();
      disk.values = after;
    }

    for (final next in <String?>[null, 'member-b']) {
      test('to ${next ?? 'nobody'}', () async {
        await push('c0', 'Zed', 'warm');
        final mark = shade.shows.length;
        final pending = [
          for (var i = 0; i < secrets.length; i++)
            push('c${i + 1}', 'Ava', secrets[i]),
        ];
        while (shade.shows.length == mark) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }

        await inTheAppIsolate(next);
        final switched = DateTime.now();
        final results = <bool?>[];
        for (final f in pending) {
          results.add(await f.then<bool?>((r) => r, onError: (_) => null));
        }

        final before = jsonEncode([
          for (final s in shade.shows)
            if (!s.at.isAfter(switched)) s.n,
        ]);
        final after = [
          for (final s in shade.shows)
            if (s.at.isAfter(switched)) s.n,
        ];
        expect(after, isEmpty, reason: 'posted after the owner changed');
        expect(results, contains(false), reason: '$results');
        for (var i = 0; i < secrets.length; i++) {
          if (results[i] == true) {
            expect(
              before,
              contains(secrets[i]),
              reason: 'show() said ${secrets[i]} is shown; it never was',
            );
          }
        }
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  });

  group('PushReceiptLog', () {
    Future<List<Map<String, Object?>>> receipts() async {
      newIsolate();
      return PushReceiptLog.pending();
    }

    setUp(() => PushReceiptLog.clear());

    test('a note is stored as the receipt\'s text', () async {
      await PushReceiptLog.add(
        'received',
        messageId: _msg,
        note: 'sent=1 dart=2 native=?',
      );

      final r = (await receipts()).single;
      expect(r['error'], 'sent=1 dart=2 native=?');
      expect(r['message_id'], _msg);
    });

    test('no note and an error: the error\'s type only, as before', () async {
      await PushReceiptLog.add('error', error: StateError(_body));

      expect((await receipts()).single['error'], 'StateError');
    });

    group('takeArrival', () {
      test('reads what the native receiver wrote, as native=ms '
          'prio=delivered/original, and removes it', () async {
        disk.values[_arrivalKey(_msg)] = '1700000000123,high,normal';
        newIsolate();

        expect(
          await PushReceiptLog.takeArrival(_msg),
          'native=1700000000123 prio=high/normal',
        );
        expect(disk.values.containsKey(_arrivalKey(_msg)), isFalse);
        newIsolate();
        expect(await PushReceiptLog.takeArrival(_msg), isNull);
      });

      test('a value written natively under a live isolate\'s cached copy is '
          'still read (FCM keeps its background isolate alive)', () async {
        await PushReceiptLog.takeArrival('warm-up');
        await SharedPreferences.getInstance();
        disk.values[_arrivalKey(_msg)] = '1700000000123,high,high';

        expect(
          await PushReceiptLog.takeArrival(_msg),
          'native=1700000000123 prio=high/high',
        );
      });

      test('another message\'s note is left alone', () async {
        disk.values[_arrivalKey('other')] = '1,high,high';
        newIsolate();

        expect(await PushReceiptLog.takeArrival(_msg), isNull);
        expect(disk.values.containsKey(_arrivalKey('other')), isTrue);
      });

      test('null id: null', () async {
        expect(await PushReceiptLog.takeArrival(null), isNull);
      });

      for (final bad in <Object>[
        'garbage',
        'abc,high,high',
        '1700000000123,high',
        '',
        42,
      ]) {
        test('a malformed value ($bad): null, no throw', () async {
          disk.values[_arrivalKey(_msg)] = bad;
          newIsolate();

          expect(await PushReceiptLog.takeArrival(_msg), isNull);
        });
      }

      test('a preferences file that cannot be read: null, no throw', () async {
        messenger.setMockMethodCallHandler(_prefsChannel, (call) async {
          throw PlatformException(code: 'io', message: 'disk gone');
        });
        newIsolate();

        expect(await PushReceiptLog.takeArrival(_msg), isNull);
      });
    });
  });

  group('onBackgroundPush: the received receipt carries the timings', () {
    RemoteMessage message({DateTime? sent, bool fields = true}) =>
        RemoteMessage(
          sentTime: sent,
          data: {
            'conversation_id': _chat,
            if (fields) 'title': _title,
            'body': _body,
            'message_id': _msg,
            'user_id': 'member-a',
          },
        );

    Future<List<Map<String, Object?>>> run(RemoteMessage m) async {
      newIsolate();
      await PushReceiptLog.clear();
      newIsolate();
      await onBackgroundPush(m);
      newIsolate();
      return PushReceiptLog.pending();
    }

    final shape = RegExp(r'^sent=(\d+|\?) dart=(\d+) native=(\d+|\?)');

    void expectSafe(Map<String, Object?> r) {
      final text = jsonEncode(r);
      for (final s in [_title, 'Zelda', _body, 'confidential', _chat]) {
        expect(text, isNot(contains(s)), reason: text);
      }
      expect((r['error']! as String).length, lessThanOrEqualTo(300));
    }

    test('sent, dart and native times, and the priorities; the arrival '
        'note is taken', () async {
      final sent = DateTime.now().subtract(const Duration(seconds: 3));
      disk.values[_arrivalKey(_msg)] = '1700000000123,high,normal';
      final before = DateTime.now().millisecondsSinceEpoch;

      final all = await run(message(sent: sent));
      final after = DateTime.now().millisecondsSinceEpoch;

      expect([for (final r in all) r['stage']], ['received', 'shown']);
      final note = all.first['error']! as String;
      final m = shape.firstMatch(note);
      expect(m, isNotNull, reason: note);
      expect(m!.group(1), '${sent.millisecondsSinceEpoch}');
      final dart = int.parse(m.group(2)!);
      expect(dart, inInclusiveRange(before, after));
      expect(m.group(3), '1700000000123');
      expect(note, contains('prio=high/normal'));
      expectSafe(all.first);
      expect(all.last['error'], isNull, reason: 'terminal unchanged');
      expect(disk.values.containsKey(_arrivalKey(_msg)), isFalse);
    });

    test('no sent time and no native note: sent=? and native=?', () async {
      final all = await run(message());

      final note = all.first['error']! as String;
      final m = shape.firstMatch(note);
      expect(m, isNotNull, reason: note);
      expect(m!.group(1), '?');
      expect(m.group(3), '?');
      expectSafe(all.first);
    });

    test('a dropped push still gets its timings on received', () async {
      final all = await run(message(fields: false));

      expect(
        [for (final r in all) r['stage']],
        ['received', 'dropped:missing_fields'],
      );
      expect(shape.hasMatch(all.first['error']! as String), isTrue);
      expectSafe(all.first);
    });

    test(
      'a malformed native note: the push is still shown, native=?',
      () async {
        disk.values[_arrivalKey(_msg)] = 'not,a,number';

        final all = await run(message());

        expect([for (final r in all) r['stage']], ['received', 'shown']);
        final note = all.first['error']! as String;
        expect(shape.firstMatch(note)?.group(3), '?', reason: note);
      },
    );
  });

  // The real snapshot store and the real avatar cache, at the directories
  // production resolves through path_provider.
  Future<void> phoneHas({String owner = 'member-a'}) async {
    await FileChatListSnapshotStore().save(owner, const [
      Conversation(
        id: 'c1',
        other: Member(
          userId: 'u-ava',
          displayName: 'Ava',
          avatarPath: 'u-ava/pic.jpg',
        ),
      ),
      Conversation(id: 'g1', title: 'Team', avatarPath: 'groups/g1.jpg'),
      Conversation(
        id: 'c3',
        other: Member(userId: 'u-cy', displayName: 'Cy'),
      ),
      Conversation(
        id: 'c4',
        other: Member(
          userId: 'u-dee',
          displayName: 'Dee',
          avatarPath: 'u-dee/never-cached.jpg',
        ),
      ),
    ]);
    final files = FileAttachmentCache();
    await files.write('u-ava/pic.jpg', _ava);
    await files.write('groups/g1.jpg', _team);
  }

  group('NotificationAvatars.forChats', () {
    test('the other member\'s picture for a 1:1, the group\'s for a group; '
        'nothing for a chat with no picture or no cached file', () async {
      await phoneHas();

      final got = await NotificationAvatars.forChats('member-a', [
        'c1',
        'g1',
        'c3',
        'c4',
        'unknown',
      ]);

      expect(got.keys.toSet(), {'c1', 'g1'});
      expect(got['c1'], _ava);
      expect(got['g1'], _team);
    });

    test('only the chats asked for', () async {
      await phoneHas();

      final got = await NotificationAvatars.forChats('member-a', ['g1']);

      expect(got.keys, ['g1']);
    });

    test('another member\'s snapshot: nothing', () async {
      await phoneHas(owner: 'member-b');

      expect(await NotificationAvatars.forChats('member-a', ['c1']), isEmpty);
    });

    test('no snapshot: nothing', () async {
      expect(await NotificationAvatars.forChats('member-a', ['c1']), isEmpty);
    });

    test('a corrupt snapshot: nothing, no throw', () async {
      await phoneHas();
      for (final f in support.listSync(recursive: true).whereType<File>()) {
        await f.writeAsString('{not json');
      }

      expect(await NotificationAvatars.forChats('member-a', ['c1']), isEmpty);
    });

    test('path_provider throws: nothing, no throw', () async {
      await phoneHas();
      pathThrows = PlatformException(code: 'io', message: 'no dir');

      expect(await NotificationAvatars.forChats('member-a', ['c1']), isEmpty);
    });

    test('path_provider has no platform side: nothing, no throw', () async {
      await phoneHas();
      pathThrows = MissingPluginException('no path_provider');

      expect(await NotificationAvatars.forChats('member-a', ['c1']), isEmpty);
    });
  });

  group('the Android post carries the picture', () {
    Map<String, Object?> spec(Map<String, Object?> n) =>
        Map<String, Object?>.from(n['platformSpecifics']! as Map);

    /// Every Person (any map with a 'name') in [n], by name.
    List<Map<Object?, Object?>> people(Object? n, String name) => [
      if (n is Map && n['name'] == name) n,
      if (n is Map)
        for (final v in n.values) ...people(v, name),
      if (n is List)
        for (final v in n) ...people(v, name),
    ];

    test('a 1:1: the large icon and the sender\'s Person icon are the '
        'other member\'s picture', () async {
      await phoneHas();

      expect(await push('c1', 'Ava', 'hi'), isTrue);

      final n = shade.childFor('c1');
      expect(spec(n)['largeIcon'], _ava);
      final ava = people(spec(n), 'Ava');
      expect(ava, isNotEmpty);
      expect([for (final p in ava) p['icon']], anyElement(equals(_ava)));
    });

    test('a group: the large icon is the group\'s picture', () async {
      await phoneHas();

      expect(await push('g1', 'Ben @ Team', 'yo'), isTrue);

      expect(spec(shade.childFor('g1'))['largeIcon'], _team);
    });

    test('no picture on the phone: shown, with no large icon', () async {
      await phoneHas();

      expect(await push('c3', 'Cy', 'hey'), isTrue);
      expect(await push('c4', 'Dee', 'hey'), isTrue);

      expect(spec(shade.childFor('c3'))['largeIcon'], isNull);
      expect(spec(shade.childFor('c4'))['largeIcon'], isNull);
    });

    test('the picture lookup fails: the push is still shown', () async {
      await phoneHas();
      pathThrows = PlatformException(code: 'io', message: 'no dir');

      expect(await push('c1', 'Ava', 'hi'), isTrue);

      expect(Shade.text(shade.childFor('c1')), contains('hi'));
      expect(spec(shade.childFor('c1'))['largeIcon'], isNull);
    });
  });

  group('clear() and the iPhone\'s delivered pushes', () {
    late List<MethodCall> ios;
    Object? iosThrows;

    setUp(() {
      ios = [];
      iosThrows = null;
      messenger.setMockMethodCallHandler(_iosChannel, (call) async {
        ios.add(call);
        if (iosThrows != null) throw iosThrows!;
        return null;
      });
    });

    Future<void> onIphone() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();
      await LocalPushDisplay.init();
    }

    test('on iOS: clearThread with the conversation id as a plain '
        'String', () async {
      await onIphone();

      await LocalPushDisplay.clear(_chat);

      expect(ios, hasLength(1));
      expect(ios.single.method, 'clearThread');
      expect(ios.single.arguments, isA<String>());
      expect(ios.single.arguments, _chat);
    });

    test('on iOS: a PlatformException is swallowed', () async {
      await onIphone();
      iosThrows = PlatformException(code: 'x');

      await expectLater(LocalPushDisplay.clear(_chat), completes);
    });

    test('on iOS: no native handler (MissingPluginException) is '
        'swallowed', () async {
      await onIphone();
      messenger.setMockMethodCallHandler(_iosChannel, null);

      await expectLater(LocalPushDisplay.clear(_chat), completes);
    });

    test('on Android: no clearThread, and the chat is still cleared', () async {
      expect(await push('c1', 'Ava', 'hi'), isTrue);

      await LocalPushDisplay.clear('c1');

      expect(ios, isEmpty);
      expect(shade.childChats, isNot(contains('c1')));
    });
  });
}
