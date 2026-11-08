// attachmentThumbProvider, written from its contract: the small copy's bytes
// when the repository has one; the full file (attachmentBytesProvider) when
// it has none; the repository's Failure as an error, never retried and never
// silently replaced by the full download; one answer per account.
import 'dart:typed_data';

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
final small = Uint8List.fromList([1, 2, 3]);

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
  test('a photo with a small copy shows it and never downloads the full '
      'file', () async {
    final chat = ChatFake()
      ..store('c1/a.png')
      ..thumbBytes['c1/a.png'] = small;
    final c = await scope(chat);

    final bytes = await c.read(attachmentThumbProvider('c1/a.png').future);

    expect(bytes, small);
    expect(chat.thumbRequests, ['c1/a.png']);
    expect(chat.bytesRequests, isEmpty);
  });

  test('an old photo without a small copy shows the full file', () async {
    final full = Uint8List.fromList([9, 9]);
    final chat = ChatFake()..store('c1/old.png', full);
    final c = await scope(chat);

    final bytes = await c.read(attachmentThumbProvider('c1/old.png').future);

    expect(bytes, full);
    expect(chat.thumbRequests, ['c1/old.png']);
    expect(chat.bytesRequests, ['c1/old.png']);
  });

  test('a full-file failure after a miss surfaces as that Failure', () async {
    const failure = NetworkFailure('storage is down');
    final chat = ChatFake()..bytesFailures['c1/old.png'] = failure;
    final c = await scope(chat);
    c.listen(attachmentThumbProvider('c1/old.png'), (_, _) {});

    await expectLater(
      c.read(attachmentThumbProvider('c1/old.png').future),
      throwsA(same(failure)),
    );
  });

  test('an Err from the small copy is the error itself, with no full '
      'download behind it', () async {
    const failure = NetworkFailure('storage is down');
    final chat = ChatFake()
      ..store('c1/a.png')
      ..thumbFailures['c1/a.png'] = failure;
    final c = await scope(chat);
    c.listen(attachmentThumbProvider('c1/a.png'), (_, _) {});

    await expectLater(
      c.read(attachmentThumbProvider('c1/a.png').future),
      throwsA(same(failure)),
    );
    final state = c.read(attachmentThumbProvider('c1/a.png'));
    expect(state, isA<AsyncError>());
    expect(state.error, same(failure));
    expect(chat.bytesRequests, isEmpty);
  });

  test('a failure is not retried behind the screen\'s back', () async {
    final chat = ChatFake()..thumbFailures['c1/a.png'] = const DeniedFailure();
    final c = await scope(chat);
    c.listen(attachmentThumbProvider('c1/a.png'), (_, _) {});

    await Future<void>.delayed(const Duration(seconds: 2));

    expect(chat.thumbRequests, ['c1/a.png']);
    expect(c.read(attachmentThumbProvider('c1/a.png')), isA<AsyncError>());
  });

  test('rebuilds on account switch: a new account asks again', () async {
    final chat = ChatFake()..thumbBytes['c1/a.png'] = small;
    final c = await scope(chat);
    c.listen(attachmentThumbProvider('c1/a.png'), (_, _) {});
    await c.read(attachmentThumbProvider('c1/a.png').future);

    (c.read(sessionControllerProvider.notifier) as _Switchable).switchTo(bob);
    await c.read(sessionControllerProvider.future);
    await c.read(attachmentThumbProvider('c1/a.png').future);

    expect(chat.thumbRequests, ['c1/a.png', 'c1/a.png']);
  });
}
