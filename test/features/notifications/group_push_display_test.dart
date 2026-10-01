// 0.30.6: a group's notification names the group, each line its sender.
// Written from the contract, not the code.
//
// Two halves:
// - LocalPushDisplay.show with the server's separate sender/chat: the
//   conversation is titled by the group, each line's person is the sender,
//   the collapsed body is "Sender: text", the summary line "Chat: Sender:
//   text"; without both, the old parsePushTitle path.
// - The seam: test/fixtures/push/android_data_payloads.json, which the edge
//   test (test/edge/notify_on_message_test.ts) proves is exactly what the
//   real notify-on-message sends, fed through the real background handler
//   (onBackgroundPush) as FCM hands it over.
//
// The device is the shared fakes in test/support/push_platform.dart.
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
import 'package:sis/features/notifications/data/firebase_push_source.dart';
import 'package:sis/features/notifications/data/local_push_display.dart';

import '../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _owner = 'member-a';

/// The MessagingStyle Android is asked to draw for [n].
Map<String, Object?> _style(Map<String, Object?> n) =>
    Map<String, Object?>.from(
      (n['platformSpecifics']! as Map)['styleInformation']! as Map,
    );

/// Each line's person, in order.
List<Object?> _people(Map<String, Object?> n) => [
  for (final m in _style(n)['messages']! as List) (m as Map)['person']['name'],
];

List<Object?> _summaryLines(Shade shade) =>
    _style(shade.summaries.single)['lines']! as List;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late Directory support;

  setUpAll(() async {
    setupFirebaseCoreMocks();
    await Firebase.initializeApp();
  });

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shade = Shade();
    support = await Directory.systemTemp.createTemp('sis-group-push-');
    messenger.setMockMethodCallHandler(Shade.channel, shade.handle);
    messenger.setMockMethodCallHandler(_prefsChannel, DiskPrefs().handle);
    messenger.setMockMethodCallHandler(_pathChannel, (_) async => support.path);
    SharedPreferences.resetStatic();
    await LocalPushDisplay.init();
    await LocalPushDisplay.forUser(_owner);
  });

  tearDown(() async {
    // A flush still pacing its posts finishes before the next test.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(Shade.channel, null);
    messenger.setMockMethodCallHandler(_prefsChannel, null);
    messenger.setMockMethodCallHandler(_pathChannel, null);
    await support.delete(recursive: true);
  });

  group('show with the server\'s sender and chat', () {
    test('the group is the title, the sender is the line\'s person, the '
        'collapsed body and the summary line name the sender', () async {
      await LocalPushDisplay.show(
        conversationId: 'g1',
        title: 'Ava @ Team',
        body: 'hi',
        sender: 'Ava',
        chat: 'Team',
      );

      final n = shade.childFor('g1');
      expect(n['title'], 'Team');
      expect(n['body'], 'Ava: hi');
      expect(_style(n)['conversationTitle'], 'Team');
      expect(_style(n)['groupConversation'], isTrue);
      expect(_people(n), ['Ava']);
      expect(_summaryLines(shade), ['Team: Ava: hi']);
    });

    test('the separate fields win where the title cannot be parsed back: a '
        'sender whose name holds " @ "', () async {
      // "Ann @ HQ @ Team" parses to sender "Ann", chat "HQ @ Team".
      await LocalPushDisplay.show(
        conversationId: 'g1',
        title: 'Ann @ HQ @ Team',
        body: 'hi',
        sender: 'Ann @ HQ',
        chat: 'Team',
      );

      final n = shade.childFor('g1');
      expect(n['title'], 'Team');
      expect(_people(n), ['Ann @ HQ']);
      expect(n['body'], 'Ann @ HQ: hi');
    });

    test('preview sender: the group titles "Sender: New message"', () async {
      await LocalPushDisplay.show(
        conversationId: 'g1',
        title: 'Ava',
        body: 'New message',
        sender: 'Ava',
        chat: 'Team',
      );

      final n = shade.childFor('g1');
      expect(n['title'], 'Team');
      expect(n['body'], 'Ava: New message');
      expect(_style(n)['groupConversation'], isTrue);
    });

    test('two senders in one group: one entry, each line its own person, '
        'the newest collapsed', () async {
      await LocalPushDisplay.show(
        conversationId: 'g1',
        title: 'Ava @ Team',
        body: 'one',
        sender: 'Ava',
        chat: 'Team',
      );
      await LocalPushDisplay.show(
        conversationId: 'g1',
        title: 'Ben @ Team',
        body: 'two',
        sender: 'Ben',
        chat: 'Team',
      );

      expect(shade.children, hasLength(1));
      final n = shade.childFor('g1');
      expect(n['title'], 'Team');
      expect(_people(n), ['Ava', 'Ben']);
      expect(n['body'], 'Ben: two');
      expect(_summaryLines(shade), ['Team: Ben: two']);
    });
  });

  group('fallback to the title', () {
    Future<void> show(String title, {String? sender, String? chat}) =>
        LocalPushDisplay.show(
          conversationId: 'c1',
          title: title,
          body: 'hi',
          sender: sender,
          chat: chat,
        );

    void expectDirect(String name) {
      final n = shade.childFor('c1');
      expect(n['title'], name);
      expect(_style(n)['groupConversation'], isFalse);
      expect(_style(n)['conversationTitle'], isNull);
      expect(_people(n), [name]);
    }

    test('neither field, a 1:1 title: a 1:1 as before', () async {
      await show('Ava');
      expectDirect('Ava');
    });

    test('neither field, an "A @ B" title: parsed into a group, as before '
        '(an older server)', () async {
      await show('Ava @ Team');
      final n = shade.childFor('c1');
      expect(n['title'], 'Team');
      expect(_style(n)['groupConversation'], isTrue);
      expect(_people(n), ['Ava']);
    });

    test('sender alone is ignored', () async {
      await show('Ava', sender: 'Ben');
      expectDirect('Ava');
    });

    test('chat alone is ignored', () async {
      await show('Ava', chat: 'Team');
      expectDirect('Ava');
    });
  });

  group('the seam: the real server payload through the real handler', () {
    late Map<String, Map<String, String>> fixture;

    setUpAll(() {
      final raw = jsonDecode(
        File('test/fixtures/push/android_data_payloads.json')
            .readAsStringSync(),
      ) as Map<String, Object?>;
      fixture = {
        for (final e in raw.entries)
          e.key: Map<String, String>.from(e.value! as Map),
      };
    });

    /// FCM hands [kind] over to this phone, for conversation [chat].
    Future<void> deliver(
      String kind,
      String chat, {
      Map<String, String> edit = const {},
    }) => onBackgroundPush(
      RemoteMessage(
        data: {
          for (final e in fixture[kind]!.entries)
            e.key: switch (e.value) {
              '<user>' => _owner,
              '<conversation>' => chat,
              '<message>' =>
                '00000000-0000-4000-8000-0000000000${chat.length}1',
              _ => e.value,
            },
          ...edit,
        },
      ),
    );

    test(
      'group, preview full: titled by the group, "Ann Sender: text"',
      () async {
        await deliver('group_full', 'g-team');

        final n = shade.childFor('g-team');
        expect(n['title'], 'Edge Team');
        expect(n['body'], 'Ann Sender: edge seam hello');
        expect(_style(n)['groupConversation'], isTrue);
        expect(_people(n), ['Ann Sender']);
        expect(_summaryLines(shade), [
          'Edge Team: Ann Sender: edge seam hello',
        ]);
      },
    );

    test('group, preview sender: titled by the group, no text', () async {
      await deliver('group_sender', 'g-team');

      final n = shade.childFor('g-team');
      expect(n['title'], 'Edge Team');
      expect(n['body'], 'Ann Sender: New message');
      expect(Shade.text(n), isNot(contains('edge seam hello')));
    });

    test(
      'group, preview none: neither the sender nor the group anywhere',
      () async {
        await deliver('group_none', 'g-team');

        final n = shade.childFor('g-team');
        expect(n['title'], 'SIS');
        expect(_style(n)['groupConversation'], isFalse);
        final all = jsonEncode(shade.posted.values.toList());
        expect(all, isNot(contains('Ann')));
        expect(all, isNot(contains('Edge Team')));
      },
    );

    test('1:1: the person is the title, not a group', () async {
      await deliver('direct_full', 'd-ann');

      final n = shade.childFor('d-ann');
      expect(n['title'], 'Ann Sender');
      expect(n['body'], 'edge direct hello');
      expect(_style(n)['groupConversation'], isFalse);
      expect(_style(n)['conversationTitle'], isNull);
    });

    test('an empty sender is absent: the title is parsed instead', () async {
      await deliver('direct_full', 'd-ann', edit: {'sender': '', 'chat': 'X'});

      final n = shade.childFor('d-ann');
      expect(n['title'], 'Ann Sender');
      expect(_style(n)['groupConversation'], isFalse);
    });

    test('an empty chat is absent: the title is parsed instead', () async {
      await deliver('direct_full', 'd-ann', edit: {'sender': 'X', 'chat': ''});

      final n = shade.childFor('d-ann');
      expect(n['title'], 'Ann Sender');
      expect(_people(n), ['Ann Sender']);
      expect(_style(n)['groupConversation'], isFalse);
    });
  });
}
