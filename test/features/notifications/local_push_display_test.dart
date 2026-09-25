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

/// The notification shade: every posted notification by id.
class Shade {
  final posted = <int, Map<String, Object?>>{};

  Map<String, Object?> _specifics(Map<String, Object?> n) =>
      Map<String, Object?>.from(
        (n['platformSpecifics'] as Map?) ?? const <String, Object?>{},
      );

  bool _isSummary(Map<String, Object?> n) =>
      _specifics(n)['setAsGroupSummary'] == true;

  List<Map<String, Object?>> get summaries => [
    for (final n in posted.values)
      if (_isSummary(n)) n,
  ];

  List<Map<String, Object?>> get children => [
    for (final n in posted.values)
      if (!_isSummary(n)) n,
  ];

  /// The chat a child opens when tapped.
  Set<Object?> get childChats => {for (final n in children) n['payload']};

  Map<String, Object?> childFor(String conversationId) =>
      children.singleWhere((n) => n['payload'] == conversationId);

  Set<Object?> get groupKeys => {
    for (final n in posted.values) _specifics(n)['groupKey'],
  };

  /// Everything a person could read on [n], expanded or not.
  static String text(Map<String, Object?> n) => jsonEncode(n);

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments;
    switch (call.method) {
      case 'initialize':
        return true;
      case 'show':
        final n = Map<String, Object?>.from(args as Map);
        posted[n['id']! as int] = n;
        return null;
      case 'cancel':
        posted.remove(args is Map ? args['id'] : args);
        return null;
      case 'cancelAll':
        posted.clear();
        return null;
      case 'getActiveNotifications':
        return [
          for (final n in posted.values)
            {
              'id': n['id'],
              'title': n['title'],
              'body': n['body'],
              'payload': n['payload'],
              'groupKey': _specifics(n)['groupKey'],
            },
        ];
      default:
        return null;
    }
  }
}

/// Android's SharedPreferences file: one store, shared by every isolate.
class DiskPrefs {
  Map<String, Object> values = {};

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    switch (call.method) {
      case 'getAll':
        return Map<String, Object>.of(values);
      case 'getAllWithParameters':
        final prefix = args['prefix'] as String;
        final allow = (args['allowList'] as List?)?.cast<String>().toSet();
        return {
          for (final e in values.entries)
            if (e.key.startsWith(prefix) &&
                (allow == null || allow.contains(e.key)))
              e.key: e.value,
        };
      case 'remove':
        values.remove(args['key']);
        return true;
      case 'clear':
        values.clear();
        return true;
      case 'clearWithParameters':
        final prefix = args['prefix'] as String;
        values.removeWhere((k, _) => k.startsWith(prefix));
        return true;
      default:
        if (call.method.startsWith('set')) {
          values[args['key'] as String] = args['value'] as Object;
          return true;
        }
        throw MissingPluginException(call.method);
    }
  }
}

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
