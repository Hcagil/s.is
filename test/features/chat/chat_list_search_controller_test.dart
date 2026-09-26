import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/fakes.dart';

/// ChatListSearchController from its contract: search(q) debounced 300 ms;
/// emptying the box clears at once with no request; only the latest query's
/// answer is applied; errors are dropped silently; clear() == search('').
///
/// testWidgets, so the debounce runs on fake time that only [pump] moves.
Message _m(String id, String conversation, String body, int minute) => Message(
  id: id,
  conversationId: conversation,
  senderId: 'u',
  body: body,
  createdAt: DateTime.utc(2026, 9, 1, 12, minute),
);

/// The signed-in account, switched by hand; the real one follows the session.
class _Account extends CurrentUserId {
  @override
  String? build() => 'ann';
  void become(String? id) => state = id;
}

void main() {
  late ChatFake chat;
  late ProviderContainer container;

  ChatListSearchController notifier() =>
      container.read(chatListSearchProvider.notifier);
  List<String> results() =>
      container.read(chatListSearchProvider).results.map((m) => m.id).toList();

  setUp(() {
    chat = ChatFake();
    chat.history['c1'] = [
      _m('a1', 'c1', 'abc one', 1),
      _m('a3', 'c1', 'abd three', 3),
    ];
    chat.history['c2'] = [
      _m('b2', 'c2', 'abc two', 2),
      _m('b4', 'c2', 'nothing', 4),
    ];
    container = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        currentUserIdProvider.overrideWith(_Account.new),
      ],
    );
    container.listen(chatListSearchProvider, (_, _) {});
  });

  testWidgets('waits 300 ms after the last keystroke, then asks once, for '
      'every conversation', (tester) async {
    notifier().search('ab');
    await tester.pump(const Duration(milliseconds: 100));
    notifier().search('abc');
    await tester.pump(const Duration(milliseconds: 299));
    expect(chat.searches, isEmpty, reason: 'still typing: no request yet');

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(chat.searches, [(query: 'abc', conversationId: null)]);
    expect(results(), ['b2', 'a1'], reason: 'every conversation, newest first');
  });

  testWidgets('emptying the box clears the results at once, with no request', (
    tester,
  ) async {
    notifier().search('abc');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(results(), isNotEmpty);
    final asked = chat.searches.length;

    notifier().search('');
    expect(results(), isEmpty, reason: 'cleared synchronously, not debounced');
    await tester.pump(const Duration(seconds: 1));
    expect(chat.searches.length, asked, reason: 'an empty box asks nothing');
    expect(results(), isEmpty);
  });

  testWidgets('a query emptied before the debounce fires is never sent', (
    tester,
  ) async {
    notifier().search('abc');
    await tester.pump(const Duration(milliseconds: 200));
    notifier().search('');
    await tester.pump(const Duration(seconds: 1));
    expect(chat.searches, isEmpty);
    expect(results(), isEmpty);
  });

  testWidgets('clear() is search(\'\')', (tester) async {
    notifier().search('abc');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(results(), isNotEmpty);
    final asked = chat.searches.length;

    notifier().clear();
    expect(results(), isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(chat.searches.length, asked);

    notifier().search('abc');
    await tester.pump(const Duration(milliseconds: 200));
    notifier().clear();
    await tester.pump(const Duration(seconds: 1));
    expect(
      chat.searches.length,
      asked,
      reason: 'clear() cancels a pending one',
    );
  });

  testWidgets('a slow answer to an old query never overwrites a newer one', (
    tester,
  ) async {
    final slow = chat.holdSearch();
    notifier().search('ab');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(
      chat.searches.single.query,
      'ab',
      reason: 'the old one is in flight',
    );

    notifier().search('abd');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(results(), ['a3'], reason: 'the newer answer arrived first');

    slow.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(results(), ['a3'], reason: 'the old answer came late: dropped');
  });

  testWidgets('an old answer arriving before the newer one is not applied '
      'either', (tester) async {
    final old = chat.holdSearch();
    final newer = chat.holdSearch();
    notifier().search('ab');
    await tester.pump(const Duration(milliseconds: 300));
    notifier().search('abd');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(chat.searches.map((s) => s.query), ['ab', 'abd']);

    old.complete();
    await tester.pump();
    expect(results(), isEmpty, reason: '"ab" is no longer what is asked');

    newer.complete();
    await tester.pump();
    expect(results(), ['a3']);
  });

  testWidgets('an answer landing after the box was emptied is dropped', (
    tester,
  ) async {
    final slow = chat.holdSearch();
    notifier().search('abc');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    notifier().search('');
    slow.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(results(), isEmpty);
  });

  testWidgets('a failure is dropped silently: the results stay as they were', (
    tester,
  ) async {
    notifier().search('abc');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(results(), ['b2', 'a1']);

    chat.searchResult = const Err(NetworkFailure('offline'));
    notifier().search('abd');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(chat.searches.last.query, 'abd', reason: 'it was asked');
    expect(results(), ['b2', 'a1'], reason: 'the failure changed nothing');
    expect(tester.takeException(), isNull);
  });

  // Not in the search contract itself, but the rule every per-account
  // provider already follows: another account never sees this one's data.
  testWidgets('an answer for the previous account never reaches the next', (
    tester,
  ) async {
    final slow = chat.holdSearch();
    notifier().search('abc');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(chat.searches.single.query, 'abc', reason: 'asked as ann');

    (container.read(currentUserIdProvider.notifier) as _Account).become('bob');
    expect(results(), isEmpty, reason: 'bob starts with an empty search');
    slow.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(results(), isEmpty, reason: "ann's hits must not appear for bob");
  });
}
