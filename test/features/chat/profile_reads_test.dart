// sharedLinksIn and the three profile-page providers, written from the
// contract. The providers run over ChatFake, whose reads take time and whose
// failures arrive as Err, the way the real repository answers.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/links.dart';
import 'package:sis/features/chat/domain/message.dart';

import '../../support/fakes.dart';

Message msg(String id, String body, {String? attachment}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'u2',
  body: body,
  createdAt: DateTime.utc(2026, 9, 22, 12),
  attachmentPath: attachment,
);

void main() {
  group('sharedLinksIn', () {
    test('every link of every message, in the messages\' order', () {
      final a = msg('a', 'see https://a.example/x and www.b.example.');
      final b = msg('b', 'nothing here');
      final c = msg('c', 'HTTP://C.EXAMPLE/path?q=1');
      final got = sharedLinksIn([a, b, c]);
      expect(
        [for (final s in got) (s.link.toString(), s.message.id)],
        [
          ('https://a.example/x', 'a'),
          ('https://www.b.example', 'a'),
          ('HTTP://C.EXAMPLE/path?q=1', 'c'),
        ].map((e) => (Uri.parse(e.$1).toString(), e.$2)).toList(),
      );
      // The message is the one it came from, not a copy or a neighbour.
      expect(identical(got[0].message, a), isTrue);
      expect(identical(got[1].message, a), isTrue);
      expect(identical(got[2].message, c), isTrue);
    });

    test('the same address twice in one message is two entries', () {
      final got = sharedLinksIn([
        msg('a', 'x.com? https://x.com https://x.com'),
      ]);
      expect(got.map((s) => s.link.host), ['x.com', 'x.com']);
    });

    test('newest-first input stays newest first', () {
      final newer = msg('new', 'https://new.example');
      final older = msg('old', 'https://old.example');
      expect(sharedLinksIn([newer, older]).map((s) => s.message.id), [
        'new',
        'old',
      ]);
    });

    test('a caption on a photo counts; text with no real link does not', () {
      final got = sharedLinksIn([
        msg('p', 'look https://p.example', attachment: 'c1/1.png'),
        msg('q', 'http:// is not an address'),
        msg('r', ''),
        msg('s', 'ftp://files.example'),
      ]);
      expect(got.map((s) => s.message.id), ['p']);
    });

    test('nothing in, nothing out', () {
      expect(sharedLinksIn(const []), isEmpty);
    });
  });

  group('profile providers', () {
    const maya = Member(userId: 'u1', displayName: 'Maya', tag: 'maya');
    const bob = Member(userId: 'u2', displayName: 'Bob', tag: 'bob');
    const ada = Member(userId: 'u3', displayName: 'Ada', tag: 'ada');

    late ChatFake chat;
    late ProviderContainer container;

    setUp(() {
      chat = ChatFake(latency: const Duration(milliseconds: 5));
      container = ProviderContainer.test(
        overrides: [chatRepositoryProvider.overrideWithValue(chat)],
      );
    });

    int callsTo(String name) => chat.calls.where((c) => c == name).length;

    test('conversationMembersProvider reads that conversation', () async {
      chat.roster['g1'] = [maya, bob, ada];
      chat.roster['g2'] = [maya];
      final sub = container.listen(
        conversationMembersProvider('g1'),
        (_, _) {},
      );
      final got = await container.read(
        conversationMembersProvider('g1').future,
      );
      expect(got.map((m) => m.userId), ['u3', 'u2', 'u1']);
      expect(chat.calls, contains('conversationMembers:g1'));
      expect(chat.calls, isNot(contains('conversationMembers:g2')));
      sub.close();
    });

    test(
      'sharedMediaProvider and sharedLinksProvider read their own id',
      () async {
        chat.history['c1'] = [
          msg('1', '', attachment: 'c1/1.png'),
          msg('2', 'https://x.example'),
        ];
        final s1 = container.listen(sharedMediaProvider('c1'), (_, _) {});
        final s2 = container.listen(sharedLinksProvider('c1'), (_, _) {});
        final media = await container.read(sharedMediaProvider('c1').future);
        final links = await container.read(sharedLinksProvider('c1').future);
        expect(media.map((m) => m.id), ['1']);
        expect(links, isNotEmpty);
        expect(chat.calls, containsAll(['sharedMedia:c1', 'sharedLinks:c1']));
        s1.close();
        s2.close();
      },
    );

    final failing =
        <
          (
            String,
            String,
            ProviderSubscription<AsyncValue<Object?>> Function(
              ProviderContainer,
            ),
          )
        >[
          (
            'conversationMembersProvider',
            'conversationMembers:c1',
            (c) => c.listen(conversationMembersProvider('c1'), (_, _) {}),
          ),
          (
            'sharedMediaProvider',
            'sharedMedia:c1',
            (c) => c.listen(sharedMediaProvider('c1'), (_, _) {}),
          ),
          (
            'sharedLinksProvider',
            'sharedLinks:c1',
            (c) => c.listen(sharedLinksProvider('c1'), (_, _) {}),
          ),
        ];
    for (final (name, call, listen) in failing) {
      test('$name: Err becomes AsyncError carrying the Failure, '
          'and is not retried on its own', () async {
        const failure = NetworkFailure('no route to host');
        chat
          ..conversationMembersResult = const Err(failure)
          ..sharedMediaResult = const Err(failure)
          ..sharedLinksResult = const Err(failure);
        final sub = listen(container);
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(sub.read(), isA<AsyncError<Object?>>());
        expect(
          sub.read().error,
          same(failure),
          reason: 'the Failure itself, not a wrapper',
        );
        expect(callsTo(call), 1);
        // Riverpod retries a failed provider by default, with a backoff that
        // starts at 200 ms. The contract says no automatic retry: the screen
        // shows the reason and stays there.
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(callsTo(call), 1, reason: 'the provider retried by itself');
        expect(sub.read(), isA<AsyncError<Object?>>());
        sub.close();
      });
    }

    test('autoDispose: unwatched, it is dropped and read afresh', () async {
      chat.roster['g1'] = [maya];
      final first = container.listen(
        conversationMembersProvider('g1'),
        (_, _) {},
      );
      await container.read(conversationMembersProvider('g1').future);
      first.close();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      chat.roster['g1'] = [maya, bob];
      final second = container.listen(
        conversationMembersProvider('g1'),
        (_, _) {},
      );
      final got = await container.read(
        conversationMembersProvider('g1').future,
      );
      expect(
        got,
        hasLength(2),
        reason: 'a stale cached list outlived its screen',
      );
      expect(callsTo('conversationMembers:g1'), 2);
      second.close();
    });
  });
}
