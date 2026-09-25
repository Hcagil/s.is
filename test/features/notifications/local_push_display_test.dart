// LocalPushDisplay against the two platform stores it drives: Android's
// notification shade (flutter_local_notifications' method channel) and the
// on-disk shared preferences (the shared_preferences method channel).
//
// The owner's rule: ONE SIS notification in the shade, expanding into one
// entry per chat, never one per message; opening a chat takes its entry
// out; signing out takes everything out.
//
// Both fakes below behave like the device, not like the code under test:
//
// - The shade keeps what was posted, by id. Posting the same id replaces;
//   cancel removes exactly that id. It never tidies up by itself: an empty
//   group summary the app forgets to cancel stays visible, as it can on a
//   phone.
// - The preferences store is ONE store shared by every isolate, while each
//   isolate's SharedPreferences keeps its own in-memory copy. That is the
//   inconvenient part: a push is shown by a background isolate while the
//   app's isolate, and a long-lived background isolate, each hold a copy
//   read earlier. The two "other isolate" cases write the store underneath
//   a live copy, as the other isolate's write does on a device.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/notifications/data/local_push_display.dart';

import '../../support/push_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late DiskPrefs disk;

  /// A fresh isolate: no in-memory copy of the preferences yet.
  void newIsolate() => SharedPreferences.resetStatic();

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shade = Shade();
    disk = DiskPrefs();
    messenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      shade.handle,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      disk.handle,
    );
    newIsolate();
    await LocalPushDisplay.init();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(
      const MethodChannel('dexterous.com/flutter/local_notifications'),
      null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      null,
    );
  });

  Future<void> push(String chat, String title, String body) =>
      LocalPushDisplay.show(conversationId: chat, title: title, body: body);

  group('one SIS notification, grouped by chat', () {
    test(
      'two chats: one summary and one entry per chat, in one group',
      () async {
        await push('c1', 'Ava', 'hi');
        await push('c2', 'Ben', 'yo');

        expect(shade.summaries, hasLength(1), reason: '${shade.posted}');
        expect(shade.children, hasLength(2), reason: '${shade.posted}');
        expect(shade.childChats, {'c1', 'c2'}, reason: 'a tap opens that chat');
        expect(shade.groupKeys, hasLength(1), reason: 'all in ONE group');
        expect(shade.groupKeys.single, isNotNull);
        expect(
          Shade.text(shade.summaries.single),
          contains('2 new messages in 2 chats'),
        );
        expect(
          Shade.text(shade.childFor('c1')),
          allOf(contains('Ava'), contains('hi')),
        );
        expect(
          Shade.text(shade.childFor('c2')),
          allOf(contains('Ben'), contains('yo')),
        );
      },
    );

    test('another message for the same chat updates its entry instead of '
        'adding one', () async {
      await push('c1', 'Ava', 'hi');
      await push('c1', 'Ava', 'again');

      expect(shade.children, hasLength(1), reason: 'not one per message');
      expect(shade.summaries, hasLength(1));
      expect(
        Shade.text(shade.childFor('c1')),
        allOf(contains('hi'), contains('again')),
      );
      expect(Shade.text(shade.summaries.single), contains('2 new messages'));
      expect(Shade.text(shade.summaries.single), isNot(contains('chats')));
    });
  });

  group('opening a chat', () {
    test('takes its entry out and updates the summary', () async {
      await push('c1', 'Ava', 'hi');
      await push('c1', 'Ava', 'again');
      await push('c2', 'Ben', 'yo');

      await LocalPushDisplay.clear('c1');

      expect(shade.childChats, {'c2'});
      expect(shade.summaries, hasLength(1));
      expect(Shade.text(shade.summaries.single), contains('1 new message'));
      expect(Shade.text(shade.summaries.single), isNot(contains('3 new')));
    });

    test('the last one leaves nothing behind, not an empty summary', () async {
      await push('c1', 'Ava', 'hi');
      await push('c2', 'Ben', 'yo');

      await LocalPushDisplay.clear('c1');
      await LocalPushDisplay.clear('c2');

      expect(shade.posted, isEmpty);
    });

    test('a chat with nothing waiting leaves the others alone', () async {
      await push('c1', 'Ava', 'hi');

      await LocalPushDisplay.clear('c9');

      expect(shade.childChats, {'c1'});
      expect(Shade.text(shade.summaries.single), contains('1 new message'));
    });

    test('once opened, a chat starts again from its next message', () async {
      await push('c1', 'Ava', 'old line');
      await LocalPushDisplay.clear('c1');

      await push('c1', 'Ava', 'new line');

      expect(Shade.text(shade.childFor('c1')), contains('new line'));
      expect(Shade.text(shade.childFor('c1')), isNot(contains('old line')));
      expect(Shade.text(shade.summaries.single), contains('1 new message'));
    });
  });

  group('signing out', () {
    test('empties the shade, and nothing of the last account comes back '
        'with the next one\'s first message', () async {
      await push('c1', 'Ava', 'secret');
      await push('c2', 'Ben', 'also secret');

      await LocalPushDisplay.clearAll();
      expect(shade.posted, isEmpty);

      await push('c3', 'Cy', 'hello new account');
      expect(shade.childChats, {'c3'});
      expect(Shade.text(shade.summaries.single), contains('1 new message'));
      final everything = jsonEncode(shade.posted.values.toList());
      expect(everything, isNot(contains('secret')));
      expect(everything, isNot(contains('Ava')));
    });
  });

  group('a change of member (forUser)', () {
    // Security: whoever signs in next must never see the previous member's
    // lines or counts -- not in the shade, not merged into their first
    // summary, and not left on disk for it to be merged from.

    /// Nothing of [secrets] anywhere a person or the next summary could
    /// read it: the shade, or the preferences file.
    void expectGone(List<String> secrets) {
      final shown = jsonEncode(shade.posted.values.toList());
      final stored = jsonEncode(disk.values);
      for (final s in secrets) {
        expect(shown, isNot(contains(s)), reason: 'in the shade: $shown');
        expect(stored, isNot(contains(s)), reason: 'on disk: $stored');
      }
    }

    /// The next member's first push shows their chat alone.
    Future<void> expectCleanFirstPush() async {
      await push('c-b', 'Bea', 'first for the next member');
      expect(shade.childChats, {'c-b'});
      expect(shade.summaries, hasLength(1));
      expect(Shade.text(shade.summaries.single), contains('1 new message'));
      expect(Shade.text(shade.summaries.single), isNot(contains('chats')));
    }

    test('to another member: the shade and the stored lines are gone, and '
        'their first push is theirs alone', () async {
      await LocalPushDisplay.forUser('member-a');
      await push('c1', 'Ava', 'secret one');
      await push('c2', 'Ada', 'secret two');

      await LocalPushDisplay.forUser('member-b');

      expect(shade.posted, isEmpty);
      expectGone(['secret one', 'secret two', 'Ava', 'Ada']);
      await expectCleanFirstPush();
      expectGone(['secret one', 'secret two']);
    });

    test('to nobody: the shade and the stored lines are gone at once, not '
        'only when the next member arrives', () async {
      await LocalPushDisplay.forUser('member-a');
      await push('c1', 'Ava', 'secret one');

      await LocalPushDisplay.forUser(null);

      expect(shade.posted, isEmpty);
      expectGone(['secret one', 'Ava']);

      await LocalPushDisplay.forUser('member-b');
      await expectCleanFirstPush();
    });

    test('a push for the previous member delivered late, after sign-out, is '
        'not merged into the next member\'s summary', () async {
      await LocalPushDisplay.forUser('member-a');
      await push('c1', 'Ava', 'secret one');
      await LocalPushDisplay.forUser(null);
      // FCM delivers late: the background isolate shows it while nobody
      // is signed in.
      newIsolate();
      await push('c1', 'Ava', 'late secret');

      newIsolate(); // the app, where the next member signs in
      await LocalPushDisplay.forUser('member-b');
      newIsolate(); // their first push, in a background isolate
      await expectCleanFirstPush();
      expectGone(['secret one', 'late secret', 'Ava']);
    });

    test('the same member again changes nothing', () async {
      await LocalPushDisplay.forUser('member-a');
      await push('c1', 'Ava', 'hi');

      await LocalPushDisplay.forUser('member-a');

      expect(shade.childChats, {'c1'});
      await push('c2', 'Ben', 'yo');
      expect(
        Shade.text(shade.summaries.single),
        contains('2 new messages in 2 chats'),
      );
    });

    test('the same member after the app restarts changes nothing: what '
        'arrived while it was closed is still waiting', () async {
      await LocalPushDisplay.forUser('member-a');
      newIsolate();
      await push('c1', 'Ava', 'arrived while closed'); // background isolate

      newIsolate(); // the app starts, the same member still signed in
      await LocalPushDisplay.forUser('member-a');

      expect(shade.childChats, {'c1'});
      expect(jsonEncode(disk.values), contains('arrived while closed'));
      newIsolate();
      await push('c2', 'Ben', 'yo');
      expect(
        Shade.text(shade.summaries.single),
        contains('2 new messages in 2 chats'),
      );
    });

    test('a background isolate still holding the previous member\'s copy '
        'does not bring their lines into the next member\'s push', () async {
      await LocalPushDisplay.forUser('member-a');
      await push('c1', 'Ava', 'secret one'); // a long-lived background isolate
      final beforeSwitch = Map<String, Object>.of(disk.values);

      // The app, another isolate, switches member underneath it.
      newIsolate();
      await LocalPushDisplay.forUser('member-b');
      final afterSwitch = Map<String, Object>.of(disk.values);
      // Back in the background isolate: its copy was read before the switch.
      disk.values = beforeSwitch;
      newIsolate();
      await SharedPreferences.getInstance();
      disk.values = afterSwitch;

      await expectCleanFirstPush();
      expectGone(['secret one', 'Ava']);
    });

    group('lines stored by a 0.12-pre build (one inbox for everyone)', () {
      // Exactly what the 0.12-pre LocalPushDisplay (24d7ac6) wrote for two
      // pushes, captured from that build over these fakes.
      Map<String, Object> legacy() => {
        'flutter.sis.push_inbox':
            '[{"c":"c-old-1","t":"Olga","l":["legacy secret one"],"n":1},'
            '{"c":"c-old-2","t":"Omar","l":["legacy secret two"],"n":1}]',
      };
      const legacySecrets = ['legacy secret one', 'legacy secret two', 'Olga'];

      test('are not merged into the first member signed in after the '
          'update', () async {
        disk.values = legacy();
        newIsolate();

        await LocalPushDisplay.forUser('member-b');
        newIsolate();
        await expectCleanFirstPush();
        expectGone(legacySecrets);
      });

      test('a push shown before the updated app was opened, then a change '
          'of member: none of it reaches the next member', () async {
        disk.values = legacy();
        newIsolate();
        await push('c-old-1', 'Olga', 'after update secret'); // no owner yet

        newIsolate(); // the updated app opens, the old member signed in
        await LocalPushDisplay.forUser('member-a');
        await LocalPushDisplay.forUser(null);
        await LocalPushDisplay.forUser('member-b');
        newIsolate();
        await expectCleanFirstPush();
        expectGone([...legacySecrets, 'after update secret']);
      });

      test('the updated app starts signed out, then a member signs in: '
          'none of it reaches them', () async {
        disk.values = legacy();
        newIsolate();

        await LocalPushDisplay.forUser(null);
        await LocalPushDisplay.forUser('member-b');
        newIsolate();
        await expectCleanFirstPush();
        expectGone(legacySecrets);
      });
    });
  });

  group('what is waiting survives the isolate that showed it', () {
    test('a push shown while the app was closed is still counted after the '
        'app starts', () async {
      await push('c1', 'Ava', 'hi'); // the background isolate
      newIsolate(); // the app, started later

      await push('c2', 'Ben', 'yo');

      expect(shade.childChats, {'c1', 'c2'});
      expect(
        Shade.text(shade.summaries.single),
        contains('2 new messages in 2 chats'),
      );
    });

    test('the app, holding an older copy, opens another chat: the push the '
        'background isolate showed meanwhile stays', () async {
      // What the background isolate leaves on disk after one push.
      await push('c1', 'Ava', 'hi');
      final afterPush = Map<String, Object>.of(disk.values);
      // The app read its preferences BEFORE that push arrived...
      disk.values = {};
      newIsolate();
      await SharedPreferences.getInstance();
      // ...and the background isolate's write lands on disk underneath it.
      disk.values = afterPush;

      await LocalPushDisplay.clear('c2'); // the member opens another chat

      expect(shade.childChats, {'c1'});
      expect(shade.summaries, hasLength(1), reason: 'c1 is still waiting');
      expect(Shade.text(shade.summaries.single), contains('1 new message'));
    });

    test('a background isolate that stayed alive does not bring back a chat '
        'the app has opened since', () async {
      await push('c1', 'Ava', 'hi'); // background isolate, kept alive
      // The app opens c1: on disk nothing is waiting any more, and its
      // notifications left the shade.
      disk.values = {};
      shade.posted.clear();

      await push('c2', 'Ben', 'yo'); // the same background isolate

      expect(shade.childChats, {'c2'});
      expect(Shade.text(shade.summaries.single), contains('1 new message'));
      expect(Shade.text(shade.summaries.single), isNot(contains('2 chats')));
    });
  });
}
