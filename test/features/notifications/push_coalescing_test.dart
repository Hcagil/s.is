// LocalPushDisplay's pacing and alerting, against the device fakes in
// test/support/push_platform.dart.
//
// The 0.25.1 defects this guards (owner, 2026-09-29): six messages arrived
// and only two were visible. Android sheds notification posts above about
// five per second per app, silently; 0.25.1 posted twice per push, so a Doze
// backlog of 13 pushes delivered within ~100 ms became 26 posts and most were
// lost. And background handlers running at once each loaded, added to and
// saved the stored inbox, overwriting each other's lines.
//
// Contract under test (not the implementation, 0.30.4): show() stores one
// line and completes true once that line is inside a posted notification,
// whichever call posted it; a flush posts every chat with something new and
// one summary, with no fixed wait before it (an idle phone posts at once) and
// consecutive plugin posts at least 300 ms apart, so never more than 4 in
// any second; only the first chat post of a flush after 8 s quiet (or the
// isolate's first flush) may alert; the summary is always silent and lets
// the children alert. Timing of the 0.30.4 changes: push_burst_test.dart.
//
// Real time on purpose: the timing IS the behaviour. The first test must stay
// first in this file: it is the isolate's first flush.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/notifications/data/local_push_display.dart';

import '../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Shade shade;
  late DiskPrefs disk;
  Object? showThrows;

  void newIsolate() => SharedPreferences.resetStatic();

  Future<Object?> plugin(MethodCall call) async {
    if (call.method == 'show' && showThrows != null) {
      shade.calls.add(call.method);
      throw showThrows!;
    }
    return shade.handle(call);
  }

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    shade = Shade();
    disk = DiskPrefs();
    showThrows = null;
    messenger.setMockMethodCallHandler(Shade.channel, plugin);
    messenger.setMockMethodCallHandler(_prefsChannel, disk.handle);
    newIsolate();
    await LocalPushDisplay.init();
    await LocalPushDisplay.forUser('member-a');
  });

  tearDown(() async {
    // Let a flush still pacing its posts finish before the fakes go away.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(Shade.channel, null);
    messenger.setMockMethodCallHandler(_prefsChannel, null);
  });

  Future<bool> push(String chat, String title, String body) =>
      LocalPushDisplay.show(conversationId: chat, title: title, body: body);

  /// Posts made since [mark] (an index into shade.shows).
  List<Map<String, Object?>> postsSince(int mark) => [
    for (final s in shade.shows.sublist(mark)) s.n,
  ];

  List<Map<String, Object?>> chatPosts(List<Map<String, Object?>> posts) => [
    for (final n in posts)
      if (!Shade.alerting(n).summary) n,
  ];

  List<Map<String, Object?>> summaryPosts(List<Map<String, Object?>> posts) => [
    for (final n in posts)
      if (Shade.alerting(n).summary) n,
  ];

  /// The alert rules every post must follow: a summary is silent and hands
  /// alerting to the children; a silent chat post alerts only once.
  void expectWellBehaved(List<Map<String, Object?>> posts) {
    for (final n in summaryPosts(posts)) {
      expect(Shade.alerting(n).silent, isTrue, reason: 'summary alerted: $n');
      expect(
        Shade.alerting(n).groupAlert,
        GroupAlertBehavior.children.index,
        reason: 'the summary must let the children alert: $n',
      );
    }
    for (final n in chatPosts(posts)) {
      if (Shade.alerting(n).silent) {
        expect(Shade.alerting(n).onlyAlertOnce, isTrue, reason: '$n');
      }
    }
  }

  group('alerting', () {
    test('the first flush of an isolate alerts once, on its first chat, and '
        'nothing else in the burst alerts', () async {
      final mark = shade.shows.length;

      await Future.wait([
        push('c1', 'Ava', 'one'),
        push('c2', 'Ben', 'two'),
        push('c3', 'Cy @ Team', 'three'),
      ]);

      final posts = postsSince(mark);
      final chats = chatPosts(posts);
      expect(chats, isNotEmpty);
      expect(
        Shade.alerting(chats.first).silent,
        isFalse,
        reason: 'the first message after quiet must be heard',
      );
      final loud = [
        for (final n in posts)
          if (!Shade.alerting(n).silent) n['payload'],
      ];
      expect(loud, hasLength(1), reason: 'one sound per burst: $loud');
      expectWellBehaved(posts);
    });

    test('a message within 8 s of the last flush is posted silently', () async {
      await push('c1', 'Ava', 'first');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final mark = shade.shows.length;

      await push('c2', 'Ben', 'soon after');

      final posts = postsSince(mark);
      expect(chatPosts(posts), isNotEmpty);
      for (final n in posts) {
        expect(Shade.alerting(n).silent, isTrue, reason: 'alerted: $n');
      }
      expectWellBehaved(posts);
    });

    test('after 8 s of quiet the next message alerts again', () async {
      await push('c1', 'Ava', 'first');
      await Future<void>.delayed(const Duration(milliseconds: 8600));
      final mark = shade.shows.length;

      await push('c2', 'Ben', 'after quiet');

      final posts = postsSince(mark);
      final chats = chatPosts(posts);
      expect(chats, isNotEmpty);
      expect(Shade.alerting(chats.first).silent, isFalse);
      expect(chats.first['payload'], 'c2');
      expectWellBehaved(posts);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('a Doze backlog: 13 pushes across 4 chats at once', () {
    // Per chat, well under maxInboxLines (25), so every line must be readable.
    final burst = [
      for (var i = 0; i < 13; i++)
        (
          chat: 'c${i % 4}',
          title: i % 4 == 3 ? 'Dee @ Crew' : 'Sender${i % 4}',
          body: 'message-$i',
        ),
    ];

    Future<void> expectEverythingVisible(List<bool> results, int mark) async {
      expect(results, everyElement(isTrue), reason: 'each push is shown');
      for (final m in burst) {
        expect(
          Shade.text(shade.childFor(m.chat)),
          contains(m.body),
          reason: '${m.body} is missing from ${m.chat}',
        );
      }
      expect(shade.children, hasLength(4));
      expect(shade.summaries, hasLength(1));
      expect(
        Shade.text(shade.summaries.single),
        contains('13 new messages from 4 chats'),
      );
      final posts = shade.shows.length - mark;
      expect(
        posts,
        lessThan(burst.length),
        reason: 'fewer posts than pushes (0.25.1 made 26); made $posts',
      );
      expect(
        shade.peakPostsPerSecond,
        lessThanOrEqualTo(5),
        reason: 'Android sheds posts above ~5/s',
      );
      expectWellBehaved(postsSince(mark));
    }

    test('delivered all at once: every message ends up in its chat, paced '
        'under the rate limit', () async {
      final mark = shade.shows.length;

      final results = await Future.wait([
        for (final m in burst) push(m.chat, m.title, m.body),
      ]);

      await expectEverythingVisible(results, mark);
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('delivered 8 ms apart: the same', () async {
      final mark = shade.shows.length;

      final pending = <Future<bool>>[];
      for (final m in burst) {
        pending.add(push(m.chat, m.title, m.body));
        await Future<void>.delayed(const Duration(milliseconds: 8));
      }
      final results = await Future.wait(pending);

      await expectEverythingVisible(results, mark);
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('handlers running at once', () {
    test('seven pushes for one chat at once: no line is lost', () async {
      final results = await Future.wait([
        for (var i = 1; i <= 7; i++) push('c1', 'Ava', 'line-$i'),
      ]);

      expect(results, everyElement(isTrue));
      final text = Shade.text(shade.childFor('c1'));
      for (var i = 1; i <= 7; i++) {
        expect(text, contains('line-$i'));
      }
      expect(Shade.text(shade.summaries.single), contains('7 new messages'));
      final stored = jsonEncode(disk.values);
      for (var i = 1; i <= 7; i++) {
        expect(stored, contains('line-$i'), reason: 'lost on disk');
      }
    });

    test('pushes that arrive while a flush is due are posted together, not '
        'once each', () async {
      await push('c1', 'Ava', 'a');
      final mark = shade.shows.length;

      final results = await Future.wait([
        push('c1', 'Ava', 'b'),
        push('c1', 'Ava', 'c'),
        push('c1', 'Ava', 'd'),
      ]);

      expect(results, everyElement(isTrue));
      final posts = postsSince(mark);
      expect(
        posts,
        hasLength(lessThanOrEqualTo(2)),
        reason: 'one chat post and one summary cover all three: $posts',
      );
      expect(
        Shade.text(shade.childFor('c1')),
        allOf(contains('b'), contains('c'), contains('d')),
      );
    });

    test('messages spread over time are never posted faster than Android '
        'accepts', () async {
      final mark = shade.shows.length;
      final pending = <Future<bool>>[];
      for (var i = 0; i < 20; i++) {
        pending.add(push('c${i % 6}', 'S$i', 'spread-$i'));
        await Future<void>.delayed(const Duration(milliseconds: 90));
      }
      expect(await Future.wait(pending), everyElement(isTrue));

      expect(shade.shows.length - mark, greaterThan(0));
      expect(shade.peakPostsPerSecond, lessThanOrEqualTo(5));
      for (var i = 0; i < 20; i++) {
        expect(Shade.text(shade.childFor('c${i % 6}')), contains('spread-$i'));
      }
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('flushes back to back', () {
    test('pushes arriving while a flush is still posting: the next flush does '
        'not post on the heels of the last one', () async {
      await push('c0', 'Zed', 'first');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final mark = shade.shows.length;

      final a = [for (var i = 1; i <= 4; i++) push('a$i', 'A$i', 'wave-a-$i')];
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final b = [for (var i = 1; i <= 4; i++) push('b$i', 'B$i', 'wave-b-$i')];
      expect(await Future.wait([...a, ...b]), everyElement(isTrue));

      final times = [for (final s in shade.shows.sublist(mark)) s.at];
      final gaps = [
        for (var i = 1; i < times.length; i++)
          times[i].difference(times[i - 1]).inMilliseconds,
      ];
      expect(
        shade.peakPostsPerSecond,
        lessThanOrEqualTo(4),
        reason: 'contract: at most ~4 posts a second; gaps (ms): $gaps',
      );
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('what the notifications carry', () {
    test('a chat opens its conversation; the summary opens nothing in '
        'particular', () async {
      await push('c1', 'Ava', 'hi');
      await push('c2', 'Ben @ Team', 'yo');

      expect(shade.childChats, {'c1', 'c2'});
      final payload = shade.summaries.single['payload'];
      expect(payload == null || payload == '', isTrue, reason: '$payload');
    });

    test('a group chat is titled by the group and each line names its '
        'sender', () async {
      await push('g1', 'Ava @ Team @ Work', 'from ava');
      await push('g1', 'Ben @ Team @ Work', 'from ben');

      final text = Shade.text(shade.childFor('g1'));
      expect(text, contains('Team @ Work'));
      expect(text, allOf(contains('Ava'), contains('Ben')));
      expect(text, allOf(contains('from ava'), contains('from ben')));
    });
  });

  group('clearing', () {
    test(
      'clear cancels the chat and re-words the summary for the rest',
      () async {
        await Future.wait([
          push('c1', 'Ava', 'hi'),
          push('c1', 'Ava', 'again'),
          push('c2', 'Ben', 'yo'),
        ]);

        await LocalPushDisplay.clear('c1');

        expect(shade.childChats, {'c2'});
        expect(Shade.text(shade.summaries.single), contains('1 new message'));
        expect(jsonEncode(disk.values), isNot(contains('again')));
      },
    );

    test('clearAll leaves the shade and the stored lines empty', () async {
      await Future.wait([push('c1', 'Ava', 'hi'), push('c2', 'Ben', 'yo')]);

      await LocalPushDisplay.clearAll();

      expect(shade.posted, isEmpty);
      expect(jsonEncode(disk.values), isNot(contains('hi')));
    });
  });

  group('a plugin that throws', () {
    test('show() throws, and the line is posted by the next flush', () async {
      showThrows = PlatformException(code: 'error', message: 'plugin broke');
      await expectLater(push('c1', 'Ava', 'first'), throwsA(anything));

      showThrows = null;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(await push('c1', 'Ava', 'second'), isTrue);

      final text = Shade.text(shade.childFor('c1'));
      expect(text, allOf(contains('first'), contains('second')));
      expect(Shade.text(shade.summaries.single), contains('2 new messages'));
    });
  });

  group('lines stored by 0.25.1 (plain text, no posted mark)', () {
    test('are kept under the new format and not posted again', () async {
      await push('c-x', 'Xan', 'probe');
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final key = disk.values.keys.singleWhere(
        (k) =>
            k.startsWith('flutter.sis.push_inbox') &&
            k != 'flutter.sis.push_inbox_owner' &&
            jsonEncode(disk.values[k]).contains('probe'),
      );
      disk.values[key] = '[{"c":"c-old","t":"Olga","l":["old line"],"n":1}]';
      newIsolate();
      shade.posted.clear();
      final mark = shade.shows.length;

      await push('c2', 'Ben', 'new elsewhere');
      expect(
        [for (final n in chatPosts(postsSince(mark))) n['payload']],
        isNot(contains('c-old')),
        reason: 'an old chat was already on screen: not dirty',
      );

      await Future<void>.delayed(const Duration(milliseconds: 700));
      await push('c-old', 'Olga', 'new line');
      expect(
        Shade.text(shade.childFor('c-old')),
        allOf(contains('old line'), contains('new line')),
      );
      expect(
        Shade.text(shade.summaries.single),
        contains('3 new messages from 2 chats'),
      );
    });
  });

  group('an owner change while a flush is posting', () {
    // Security L1 (2026-09-29). A flush in the background isolate posts
    // chats 250 ms apart; the member signs out or switches account in the
    // app's isolate meanwhile. The app isolate's write lands on disk while
    // the background isolate still holds its own, older copy.
    //
    // Expected red until the flush re-checks the owner before each post and
    // before its save.
    const secrets = ['secret-1', 'secret-2', 'secret-3', 'secret-4'];

    /// Starts a flush that will post four chats, and returns once the first
    /// of them is in the shade, the rest still to come.
    Future<List<Future<bool>>> flushUnderWay() async {
      await push('c0', 'Zed', 'warm');
      final mark = shade.shows.length;
      final pending = [
        for (var i = 0; i < secrets.length; i++)
          push('c${i + 1}', 'Ava', secrets[i]),
      ];
      while (chatPosts(postsSince(mark)).isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      return pending;
    }

    /// forUser in the app's isolate, underneath the background isolate's
    /// cached copy of the preferences.
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

    Future<void> settle(List<Future<bool>> pending) async {
      for (final f in pending) {
        await f.then<void>((_) {}, onError: (_) {});
      }
      await Future<void>.delayed(const Duration(milliseconds: 1500));
    }

    void expectNothingOfA(DateTime switched) {
      final late = [
        for (final s in shade.shows)
          if (s.at.isAfter(switched)) s.n,
      ];
      expect(late, isEmpty, reason: 'posted after the owner changed: $late');
      final shown = jsonEncode(shade.posted.values.toList());
      final stored = jsonEncode(disk.values);
      for (final s in secrets) {
        expect(shown, isNot(contains(s)), reason: 'in the shade: $shown');
        expect(stored, isNot(contains(s)), reason: 'on disk: $stored');
      }
    }

    test('signing out: no further posts, nothing left in the shade or on '
        'disk', () async {
      final pending = await flushUnderWay();

      await inTheAppIsolate(null);
      final switched = DateTime.now();
      await settle(pending);

      expectNothingOfA(switched);
    });

    test('switching to another member: no further posts, and none of the '
        'previous member\'s lines stored under the new one', () async {
      final pending = await flushUnderWay();

      await inTheAppIsolate('member-b');
      final switched = DateTime.now();
      await settle(pending);

      expectNothingOfA(switched);
      expect(await LocalPushDisplay.currentOwner(), 'member-b');
    });
  });
}
