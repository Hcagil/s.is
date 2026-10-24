// MessagesController.verifyNewest({force}), from the contract (fix
// "new messages appear at once", t_50655c1325):
// - force=false is unchanged: at most once per 20 s, never on an empty list.
// - force=true (a Realtime re-join, a foreground push) skips the 20 s limit
//   and the empty-list guard: an empty open chat is read again.
// - Both: a no-op while jumped, while a build is loading, in error, or with
//   no chat open.
// Fake time (testWidgets) so the 20 s limit is exercised without waiting.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const _me = Member(userId: 'me', displayName: 'Maya');

class _In extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

final _t0 = DateTime.utc(2026, 1, 1);

Message _m(String id, int minute, {String conv = 'c1'}) => Message(
  id: id,
  conversationId: conv,
  senderId: 'bob',
  body: 'body $id',
  createdAt: _t0.add(Duration(minutes: minute)),
);

List<Message> _history(String conv, int n) => [
  for (var i = 0; i < n; i++) _m('$conv-$i', i, conv: conv),
];

const _offline = NetworkFailure('offline', retryable: true);

void main() {
  late ChatFake chat;
  late ProviderContainer c;

  List<String> shown() =>
      c.read(messagesProvider).requireValue.map((m) => m.id).toList();
  MessagesController messages() => c.read(messagesProvider.notifier);
  int reads([String id = 'c1']) =>
      chat.calls.where((x) => x == 'messages:$id').length;

  ProviderContainer make() {
    final container = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        sessionControllerProvider.overrideWith(_In.new),
      ],
    );
    container.listen(messagesProvider, (_, _) {});
    return container;
  }

  Future<void> elapse(WidgetTester t, Duration d) async {
    const step = Duration(milliseconds: 100);
    for (var left = d; left > Duration.zero; left -= step) {
      await t.pump(left < step ? left : step);
    }
  }

  Future<void> open(WidgetTester t) async {
    c = make();
    addTearDown(c.dispose);
    await elapse(t, const Duration(milliseconds: 100));
    c.read(openConversationProvider.notifier).open('c1');
    await elapse(t, const Duration(milliseconds: 300));
    expect(c.read(messagesProvider).hasValue, isTrue, reason: 'fixture: open');
  }

  const short = Duration(milliseconds: 300);

  testWidgets('force skips the 20 s limit that still holds without it', (
    t,
  ) async {
    chat = ChatFake();
    chat.history['c1'] = _history('c1', 600);
    await open(t);
    await elapse(t, const Duration(seconds: 21));
    chat.loseRealtime();
    chat.deliver(_m('missed1', 601));
    var mark = reads();
    messages().verifyNewest();
    await elapse(t, short);
    expect(reads(), mark + 1, reason: 'past 20 s: an unforced read');
    expect(shown().last, 'missed1');

    chat.deliver(_m('missed2', 602));
    mark = reads();
    messages().verifyNewest();
    await elapse(t, short);
    expect(reads(), mark, reason: 'unforced, within 20 s: throttled');
    expect(shown(), isNot(contains('missed2')));

    messages().verifyNewest(force: true);
    await elapse(t, short);
    expect(reads(), mark + 1, reason: 'forced: no 20 s limit');
    expect(shown().last, 'missed2');
  });

  testWidgets('force reads an empty chat; unforced does not', (t) async {
    chat = ChatFake();
    chat.history['c1'] = [];
    await open(t);
    await elapse(t, const Duration(seconds: 21));
    expect(shown(), isEmpty, reason: 'fixture');
    final mark = reads();
    messages().verifyNewest();
    await elapse(t, short);
    expect(reads(), mark, reason: 'unforced: empty-list guard');

    chat.history['c1'] = [_m('first', 1)];
    messages().verifyNewest(force: true);
    await elapse(t, short);
    expect(reads(), mark + 1, reason: 'forced: an empty chat is read');
    expect(shown(), ['first']);
  });

  testWidgets('force reads at once right after the open', (t) async {
    chat = ChatFake();
    chat.history['c1'] = _history('c1', 600);
    await open(t);
    chat.loseRealtime();
    chat.deliver(_m('missed', 601));
    final mark = reads();
    messages().verifyNewest(force: true);
    await elapse(t, const Duration(milliseconds: 200));
    expect(reads(), mark + 1);
    expect(shown().last, 'missed');
  });

  testWidgets('without force the limit is 20 s', (t) async {
    chat = ChatFake();
    chat.history['c1'] = _history('c1', 600);
    await open(t);
    await elapse(t, const Duration(seconds: 21));
    final mark = reads();
    messages().verifyNewest();
    await elapse(t, short);
    expect(reads(), mark + 1);
    await elapse(t, const Duration(seconds: 10));
    messages().verifyNewest();
    await elapse(t, short);
    expect(reads(), mark + 1, reason: 'within 20 s: throttled');
    // The limit runs on the wall clock (as on main 422bf75), not fake time.
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 21)));
    messages().verifyNewest();
    await elapse(t, short);
    expect(reads(), mark + 2, reason: '>20 s later: reads again');
  }, timeout: const Timeout(Duration(minutes: 1)));

  testWidgets('force: a no-op while jumped', (t) async {
    chat = ChatFake();
    chat.history['c1'] = _history('c1', 600);
    await open(t);
    final r = messages().jumpToAround(chat.history['c1']![30]);
    await elapse(t, short);
    expect(await r, isA<Ok<void>>(), reason: 'fixture');
    expect(messages().isJumped, isTrue, reason: 'fixture');
    final mark = reads();
    messages().verifyNewest(force: true);
    await elapse(t, short);
    expect(reads(), mark);
    expect(messages().isJumped, isTrue);
  });

  testWidgets('force: a no-op while loading', (t) async {
    chat = ChatFake();
    chat.history['c1'] = _history('c1', 600);
    await open(t);
    chat.holdMessages();
    messages().catchUp();
    await elapse(t, const Duration(milliseconds: 100));
    final mark = reads();
    messages().verifyNewest(force: true);
    await elapse(t, const Duration(milliseconds: 100));
    expect(reads(), mark);
    chat.releaseMessages();
    await elapse(t, short);
  });

  testWidgets('force: a no-op with no open conversation', (t) async {
    chat = ChatFake();
    chat.history['c1'] = _history('c1', 10);
    c = make();
    addTearDown(c.dispose);
    await elapse(t, short);
    messages().verifyNewest(force: true);
    await elapse(t, short);
    expect(chat.calls.where((x) => x.startsWith('messages:')), isEmpty);
  });

  testWidgets('force: a no-op on an error', (t) async {
    chat = ChatFake();
    chat.messagesResult = const Err(DeniedFailure());
    c = make();
    addTearDown(c.dispose);
    await elapse(t, const Duration(milliseconds: 100));
    c.read(openConversationProvider.notifier).open('c1');
    await elapse(t, const Duration(seconds: 1));
    expect(c.read(messagesProvider).hasError, isTrue, reason: 'fixture');
    chat.messagesResult = Ok([_m('x', 1)]);
    final mark = reads();
    messages().verifyNewest(force: true);
    await elapse(t, short);
    expect(reads(), mark);
  });

  // Keeps _offline referenced for the retryable-error variant below.
  testWidgets('force: a no-op on a retryable error with no list', (t) async {
    chat = ChatFake();
    chat.messagesResult = const Err(_offline);
    c = make();
    addTearDown(c.dispose);
    await elapse(t, const Duration(milliseconds: 100));
    c.read(openConversationProvider.notifier).open('c1');
    await elapse(t, const Duration(seconds: 1));
    expect(c.read(messagesProvider).hasError, isTrue, reason: 'fixture');
    chat.messagesResult = Ok([_m('x', 1)]);
    final mark = reads();
    messages().verifyNewest(force: true);
    await elapse(t, short);
    expect(reads(), mark);
    await elapse(t, const Duration(seconds: 30));
  });
}
