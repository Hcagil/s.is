// ReadMarksController (readMarksProvider) when ChatRepository.readUpdates
// answers late: after the controller was rebuilt (another conversation, the
// chat closed) or disposed. Written from the contract: a stale Ok stream gets
// exactly one listen and one cancel, so the repository's onCancel leaves the
// reads:<id> channel; a fresh one stays listened until dispose; an Err has
// nothing to cancel.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// One readUpdates() call. Like the real repository, the channel is left in
/// the stream's onCancel, which a single-subscription stream only runs once
/// it was listened to.
class _Join {
  _Join(this.id);
  final String id;
  final answer = Completer<void>();
  var listens = 0;
  var cancels = 0;
  late final channel = StreamController<ReadMark>(
    onListen: () => listens++,
    onCancel: () => cancels++,
  );
}

/// readUpdates() whose join is answered only when the test says so.
class _SlowReads extends ChatFake {
  final joins = <_Join>[];
  Result<Stream<ReadMark>>? fails;
  bool hold = true;

  _Join of(String id) => joins.singleWhere((j) => j.id == id);

  @override
  Future<Result<Stream<ReadMark>>> readUpdates(String conversationId) async {
    final join = _Join(conversationId);
    joins.add(join);
    if (hold) await join.answer.future;
    if (fails case final failed?) return failed;
    return Ok(join.channel.stream);
  }
}

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 30));

Future<ProviderContainer> ready(ChatFake chat) async {
  final c = ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(chat),
      profileRepositoryProvider.overrideWithValue(
        ProfileFake(
          profile: const OwnProfile(
            userId: 'u1',
            displayName: 'Maya',
            tag: 'maya',
            onboardingDone: true,
            shareReadStatus: true,
          ),
        ),
      ),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  await settled(c);
  c.listen(ownProfileProvider, (_, _) {});
  await c.read(ownProfileProvider.future);
  return c;
}

/// Opens [id] and waits until its readUpdates() call is in flight.
Future<ProviderSubscription<AsyncValue<List<ReadMark>>>> _joining(
  ProviderContainer c,
  _SlowReads chat,
  String id,
) async {
  c.read(openConversationProvider.notifier).open(id);
  final sub = c.listen(readMarksProvider, (_, _) {});
  for (var i = 0; !chat.joins.any((j) => j.id == id); i++) {
    if (i > 100) fail('readUpdates($id) was never called');
    await settle();
  }
  return sub;
}

void main() {
  test('a join answered after switching to another conversation is listened '
      'once and cancelled once; the new one stays listened', () async {
    final chat = _SlowReads();
    final c = await ready(chat);
    await _joining(c, chat, 'c1');

    c.read(openConversationProvider.notifier).open('c2');
    await settle();
    chat.of('c2').answer.complete();
    await c.read(readMarksProvider.future);
    chat.of('c1').answer.complete();
    await settle();

    expect(chat.of('c1').listens, 1, reason: 'stale stream never listened');
    expect(chat.of('c1').cancels, 1, reason: 'reads:c1 channel never left');
    expect(chat.of('c2').listens, 1);
    expect(chat.of('c2').cancels, 0, reason: 'the open chat was left');
  });

  test('a join answered after the chat was closed is listened once and '
      'cancelled once', () async {
    final chat = _SlowReads();
    final c = await ready(chat);
    await _joining(c, chat, 'c1');

    c.read(openConversationProvider.notifier).close();
    await settle();
    chat.of('c1').answer.complete();
    await settle();

    expect(chat.of('c1').listens, 1);
    expect(chat.of('c1').cancels, 1, reason: 'reads:c1 channel never left');
    expect(await c.read(readMarksProvider.future), isEmpty);
  });

  test('a join answered after the provider was disposed is listened once and '
      'cancelled once', () async {
    final chat = _SlowReads();
    final c = await ready(chat);
    final sub = await _joining(c, chat, 'c1');

    sub.close();
    await settle();
    expect(c.exists(readMarksProvider), isFalse, reason: 'fixture: disposed');
    chat.of('c1').answer.complete();
    await settle();

    expect(chat.of('c1').listens, 1);
    expect(chat.of('c1').cancels, 1, reason: 'reads:c1 channel never left');
  });

  test('a join answered after the container was disposed is listened once '
      'and cancelled once', () async {
    final chat = _SlowReads();
    final c = await ready(chat);
    await _joining(c, chat, 'c1');

    c.dispose();
    chat.of('c1').answer.complete();
    await settle();

    expect(chat.of('c1').listens, 1);
    expect(chat.of('c1').cancels, 1, reason: 'reads:c1 channel never left');
  });

  test('a join answered in time stays listened, gets live reads, and is '
      'cancelled only on dispose', () async {
    final chat = _SlowReads()..hold = false;
    chat.readMarksData['c1'] = const [ReadMark(userId: 'u2', shares: true)];
    final c = await ready(chat);
    final sub = await _joining(c, chat, 'c1');
    await c.read(readMarksProvider.future);
    await settle();

    final join = chat.of('c1');
    expect(join.listens, 1);
    expect(join.cancels, 0, reason: 'a fresh join was left at once');
    final t0 = DateTime.utc(2026, 9, 25, 10);
    join.channel.add(ReadMark(userId: 'u2', shares: true, readAt: t0));
    await settle();
    expect(c.read(readMarksProvider).requireValue.map((m) => m.readAt), [
      t0,
    ], reason: 'the live stream is not wired to the state');

    sub.close();
    await settle();
    expect(join.cancels, 1, reason: 'still listened after dispose');
    expect(join.listens, 1);
  });

  test('a stale Err has nothing to cancel and breaks nothing', () async {
    final chat = _SlowReads()..fails = const Err(NetworkFailure('offline'));
    final c = await ready(chat);
    await _joining(c, chat, 'c1');

    c.read(openConversationProvider.notifier).open('c2');
    await settle();
    chat.of('c2').answer.complete();
    chat.of('c1').answer.complete();
    await settle();

    expect(chat.of('c1').listens, 0);
    expect(c.read(readMarksProvider).hasError, isFalse);
  });
}
