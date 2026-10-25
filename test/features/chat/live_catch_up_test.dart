// liveCatchUpProvider, from the contract (fix "new messages appear at once",
// t_50655c1325, part A):
// - it ignores every event unless the session is Allowed;
// - a Realtime re-join: storeSync runs once, the open chat is re-read at
//   once (no 20 s wait, also when it is empty), the list is reloaded;
// - a foreground push for the open chat X: one re-read of X (and the list);
//   for another chat: storeSync plus a list reload, no chat re-read;
// - rows merge by id: no duplicate bubbles.
// realtimeRejoinedProvider and foregroundPushProvider are fed from
// broadcast controllers, as main.dart feeds them.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const _me = Member(userId: 'me', displayName: 'Maya');

class _In extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

class _Out extends SessionController {
  @override
  Future<SessionState> build() async => const SignedOut();
}

var _syncs = 0;

class _CountingSync extends StoreSyncController {
  _CountingSync(super.ref);
  @override
  Future<void> run() async => _syncs++;
}

final _t0 = DateTime.utc(2026, 1, 1);

Message _m(String id, int minute, {String conv = 'c1'}) => Message(
  id: id,
  conversationId: conv,
  senderId: 'bob',
  body: 'body $id',
  createdAt: _t0.add(Duration(minutes: minute)),
);

void main() {
  late ChatFake chat;
  late ProviderContainer c;
  late StreamController<void> rejoined;
  late StreamController<String> pushed;

  List<String> shown() =>
      c.read(messagesProvider).requireValue.map((m) => m.id).toList();
  int reads([String id = 'c1']) =>
      chat.calls.where((x) => x == 'messages:$id').length;
  int anyReads() => chat.calls.where((x) => x.startsWith('messages:')).length;
  int listReads() => chat.calls.where((x) => x == 'conversations').length;

  Future<void> elapse(WidgetTester t, Duration d) async {
    const step = Duration(milliseconds: 100);
    for (var left = d; left > Duration.zero; left -= step) {
      await t.pump(left < step ? left : step);
    }
  }

  Future<void> mount(
    WidgetTester t, {
    bool allowed = true,
    String? open = 'c1',
  }) async {
    rejoined = StreamController<void>.broadcast();
    pushed = StreamController<String>.broadcast();
    addTearDown(rejoined.close);
    addTearDown(pushed.close);
    c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(allowed ? _In.new : _Out.new),
        storeSyncProvider.overrideWith(_CountingSync.new),
        realtimeRejoinedProvider.overrideWithValue(rejoined.stream),
        foregroundPushProvider.overrideWithValue(pushed.stream),
      ],
    );
    addTearDown(c.dispose);
    c.listen(liveCatchUpProvider, (_, _) {});
    c.listen(conversationListProvider, (_, _) {});
    c.listen(messagesProvider, (_, _) {});
    await elapse(t, const Duration(milliseconds: 300));
    if (open != null) {
      c.read(openConversationProvider.notifier).open(open);
      await elapse(t, const Duration(milliseconds: 500));
    }
  }

  setUp(() {
    _syncs = 0;
    chat = ChatFake();
    chat.history['c1'] = [for (var i = 0; i < 20; i++) _m('c1-$i', i)];
    chat.history['c2'] = [
      for (var i = 0; i < 5; i++) _m('c2-$i', i, conv: 'c2'),
    ];
  });

  const short = Duration(milliseconds: 300);

  group('a Realtime re-join', () {
    testWidgets('store sync once, the open chat re-read at once, the list '
        'reloaded; the missed row shows once', (t) async {
      await mount(t);
      chat.loseRealtime();
      chat.deliver(_m('gap', 30));
      final (s, r, l) = (_syncs, reads(), listReads());
      rejoined.add(null);
      await elapse(t, short);
      expect(_syncs, s + 1, reason: 'storeSync once');
      expect(reads(), r + 1, reason: 'one re-read, no 20 s wait');
      expect(listReads(), greaterThan(l), reason: 'list reloaded');
      expect(shown().last, 'gap');
      expect(shown().where((id) => id == 'gap').length, 1);
      expect(shown().toSet().length, shown().length, reason: 'merged by id');
    });

    testWidgets('a second re-join soon after is not held by the 20 s limit', (
      t,
    ) async {
      await mount(t);
      chat.loseRealtime();
      chat.deliver(_m('gap1', 30));
      rejoined.add(null);
      await elapse(t, short);
      expect(shown().last, 'gap1', reason: 'fixture: first re-join');
      chat.loseRealtime();
      chat.deliver(_m('gap2', 31));
      final r = reads();
      rejoined.add(null);
      await elapse(t, short);
      expect(reads(), r + 1, reason: 'the second re-join reads at once');
      expect(shown().last, 'gap2');
    });

    testWidgets('an empty open chat is re-read too', (t) async {
      chat.history['c1'] = [];
      await mount(t);
      expect(shown(), isEmpty, reason: 'fixture');
      chat.loseRealtime();
      chat.deliver(_m('first', 1));
      final r = reads();
      rejoined.add(null);
      await elapse(t, short);
      expect(reads(), r + 1);
      expect(shown(), ['first']);
    });

    testWidgets('with no chat open: store sync and the list only', (t) async {
      await mount(t, open: null);
      final (s, m, l) = (_syncs, anyReads(), listReads());
      rejoined.add(null);
      await elapse(t, short);
      expect(_syncs, s + 1);
      expect(anyReads(), m, reason: 'no chat to re-read');
      expect(listReads(), greaterThan(l));
    });
  });

  group('a foreground push', () {
    testWidgets('for the open chat: one re-read of it, the list reloaded', (
      t,
    ) async {
      await mount(t);
      chat.loseRealtime();
      chat.deliver(_m('pushed', 30));
      final (r, l) = (reads(), listReads());
      pushed.add('c1');
      await elapse(t, short);
      expect(reads(), r + 1, reason: 'one re-read of the open chat');
      expect(listReads(), greaterThan(l));
      expect(shown().last, 'pushed');
      expect(shown().where((id) => id == 'pushed').length, 1);
      // A second push soon after reads again (not held by the 20 s limit).
      chat.loseRealtime();
      chat.deliver(_m('pushed2', 31));
      pushed.add('c1');
      await elapse(t, short);
      expect(reads(), r + 2);
      expect(shown().last, 'pushed2');
    });

    testWidgets('for another chat: store sync and the list, no chat re-read', (
      t,
    ) async {
      await mount(t);
      final (s, m, l) = (_syncs, anyReads(), listReads());
      pushed.add('c2');
      await elapse(t, short);
      expect(_syncs, s + 1, reason: 'storeSync');
      expect(listReads(), greaterThan(l), reason: 'list reloaded');
      expect(anyReads(), m, reason: 'no chat read');
    });
  });

  group('not Allowed: every event ignored', () {
    testWidgets('re-join and pushes do nothing', (t) async {
      await mount(t, allowed: false, open: null);
      final (s, m, l) = (_syncs, anyReads(), listReads());
      rejoined.add(null);
      pushed.add('c1');
      pushed.add('c2');
      await elapse(t, short);
      expect(_syncs, s);
      expect(anyReads(), m);
      expect(listReads(), l);
    });
  });
}
