// attachmentBytesProvider, written from its contract in chat_controllers.dart:
// the repository's bytes for a path, no silent retry behind the screen's
// back, and a rebuild per account like every other per-account read.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';

import '../../support/fakes.dart';

const maya = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

/// A session a test can move from one allowed member to another, the way a
/// second Google account signing in on the same phone does.
class _Switchable extends SessionController {
  Member _member = maya;

  @override
  Future<SessionState> build() async => Allowed(_member);

  void switchTo(Member member) {
    _member = member;
    state = AsyncData(Allowed(member));
  }
}

Future<ProviderContainer> scope(ChatFake chat) => settled(
  ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(chat),
      sessionControllerProvider.overrideWith(_Switchable.new),
    ],
  ),
);

void main() {
  test('is the repository\'s bytes for that path', () async {
    final chat = ChatFake()..store('c1/a.png');
    final c = await scope(chat);

    final bytes = await c.read(attachmentBytesProvider('c1/a.png').future);

    expect(bytes, pngBytes);
    expect(chat.bytesRequests, ['c1/a.png']);
  });

  test('an Err becomes an AsyncError carrying the Failure itself', () async {
    const failure = NetworkFailure('storage is down');
    final chat = ChatFake()..bytesFailures['c1/a.png'] = failure;
    final c = await scope(chat);
    c.listen(attachmentBytesProvider('c1/a.png'), (_, _) {});

    await expectLater(
      c.read(attachmentBytesProvider('c1/a.png').future),
      throwsA(same(failure)),
    );
    final state = c.read(attachmentBytesProvider('c1/a.png'));
    expect(state, isA<AsyncError>());
    expect(state.error, same(failure));
  });

  test('a failure is not retried behind the screen\'s back', () async {
    final chat = ChatFake()..bytesFailures['c1/a.png'] = const DeniedFailure();
    final c = await scope(chat);
    c.listen(attachmentBytesProvider('c1/a.png'), (_, _) {});

    await Future<void>.delayed(const Duration(seconds: 2));

    expect(chat.bytesRequests, ['c1/a.png']);
    expect(c.read(attachmentBytesProvider('c1/a.png')), isA<AsyncError>());
  });

  test('rebuilds on account switch: a new account asks again', () async {
    final chat = ChatFake()..store('c1/a.png');
    final c = await scope(chat);
    c.listen(attachmentBytesProvider('c1/a.png'), (_, _) {});
    await c.read(attachmentBytesProvider('c1/a.png').future);
    expect(chat.bytesRequests, ['c1/a.png']);

    (c.read(sessionControllerProvider.notifier) as _Switchable).switchTo(bob);
    // The session settling on the new member must be awaited the way the
    // app does, before anything per-account is trusted.
    await c.read(sessionControllerProvider.future);
    await c.read(attachmentBytesProvider('c1/a.png').future);

    expect(
      chat.bytesRequests,
      ['c1/a.png', 'c1/a.png'],
      reason:
          'a new account must not be served the previous account\'s cached '
          'answer for the same path',
    );
  });
}
