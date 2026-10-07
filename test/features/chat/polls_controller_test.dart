// PollsController (pollsProvider) and pollVotesProvider against PollFake --
// never the SDK. Written from the contract only: vote() is optimistic and
// rolls back on Err; a closed poll gives PollClosedFailure, locally (no call)
// or from the server; retract() votes the empty set; close() is optimistic
// and reopens on Err; ensure() fetches a missing poll (force re-fetches);
// addLocal() shows at once; live count / closed changes land in state.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/poll.dart';

import '../../support/fakes.dart';
import '../../support/poll_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> until(bool Function() ok) async {
  for (var i = 0; i < 400; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('condition never held');
}

Poll poll(String id, {bool closed = false, bool anonymous = false}) => Poll(
  messageId: id,
  question: 'Lunch?',
  options: const [
    PollOption(id: 'a', text: 'A', votes: 0),
    PollOption(id: 'b', text: 'B', votes: 0),
  ],
  multiple: false,
  anonymous: anonymous,
  closed: closed,
  voters: 0,
);

Future<ProviderContainer> ready(PollFake fake) async {
  final c = ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(ChatFake()),
      pollRepositoryProvider.overrideWithValue(fake),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  await settled(c);
  c.listen(pollsProvider, (_, _) {});
  c.read(openConversationProvider.notifier).open('c1');
  await until(() => c.read(pollsProvider).value?['m1'] != null);
  // Let the post-join re-fetch land so a test ending early does not leave it
  // in flight (that case has its own test below).
  await until(() => fake.loadCalls.length >= 2);
  await turn();
  await turn();
  return c;
}

Poll st(ProviderContainer c, String id) => c.read(pollsProvider).value![id]!;

Failure failureOf(Result<void> r) => (r as Err<void>).failure;

Future<void> turn() => Future<void>.delayed(Duration.zero);

void main() {
  late PollFake fake;
  late ProviderContainer c;
  late PollsController n;

  Future<void> start([void Function(PollFake f)? extra]) async {
    fake = PollFake()
      ..seed('c1', poll('m1'), creator: 'u1')
      ..seed('c1', poll('m2'), creator: 'u2');
    extra?.call(fake);
    c = await ready(fake);
    n = c.read(pollsProvider.notifier);
  }

  test('loads the open conversation polls', () async {
    await start();
    expect(st(c, 'm1').options.map((o) => o.id), ['a', 'b']);
    expect(st(c, 'm2').question, 'Lunch?');
  });

  test('a vote shows at once, before the server answers', () async {
    await start();
    final gate = Completer<void>();
    fake.onVote = (id, s) async {
      await gate.future;
      return fake.serverVote(id, s);
    };
    final f = n.vote('m1', {'a'});
    await turn();
    expect(st(c, 'm1').mine, {'a'});
    expect(st(c, 'm1').options[0].votes, 1);
    expect(st(c, 'm1').voters, 1);
    gate.complete();
    expect(await f, isA<Ok<void>>());
    expect(fake.view('m1')!.mine, {'a'});
    expect(st(c, 'm1').mine, {'a'});
  });

  test('another option changes the vote', () async {
    await start();
    await n.vote('m1', {'a'});
    await n.vote('m1', {'b'});
    // The live echoes of both votes settle on the server's counts.
    await until(() => st(c, 'm1').options[0].votes == 0);
    final p = st(c, 'm1');
    expect(p.mine, {'b'});
    expect(p.options[0].votes, 0);
    expect(p.options[1].votes, 1);
    expect(p.voters, 1);
    expect(fake.voteCalls.last.$2, {'b'});
  });

  test('a refused vote rolls back and returns the failure', () async {
    await start();
    final gate = Completer<void>();
    fake.onVote = (id, s) async {
      await gate.future;
      return const Err(DeniedFailure());
    };
    final f = n.vote('m1', {'a'});
    await turn();
    expect(st(c, 'm1').mine, {'a'});
    gate.complete();
    final r = await f;
    expect(failureOf(r), isA<DeniedFailure>());
    final p = st(c, 'm1');
    expect(p.mine, isEmpty);
    expect(p.voters, 0);
    expect(p.options[0].votes, 0);
  });

  test('a server PollClosedFailure comes back and rolls back', () async {
    await start();
    fake.onVote = (id, s) async => const Err(PollClosedFailure());
    final r = await n.vote('m1', {'a'});
    expect(failureOf(r), isA<PollClosedFailure>());
    expect(st(c, 'm1').mine, isEmpty);
    expect(st(c, 'm1').options[0].votes, 0);
    expect(st(c, 'm1').closed, isTrue, reason: 'the server said it is closed');
  });

  test('a poll closed locally refuses without calling the server', () async {
    await start((f) => f.seed('c1', poll('m3', closed: true)));
    await until(() => c.read(pollsProvider).value?['m3'] != null);
    final r = await n.vote('m3', {'a'});
    expect(failureOf(r), isA<PollClosedFailure>());
    expect(fake.voteCalls, isEmpty);
    expect(st(c, 'm3').mine, isEmpty);
    expect(st(c, 'm3').options[0].votes, 0);
  });

  test('retract clears my vote by voting the empty set', () async {
    await start();
    await n.vote('m1', {'a'});
    final r = await n.retract('m1');
    expect(r, isA<Ok<void>>());
    await until(() => st(c, 'm1').options[0].votes == 0);
    expect(st(c, 'm1').mine, isEmpty);
    expect(st(c, 'm1').voters, 0);
    expect(st(c, 'm1').options[0].votes, 0);
    expect(fake.voteCalls.last.$1, 'm1');
    expect(fake.voteCalls.last.$2, isEmpty);
    expect(fake.view('m1')!.mine, isEmpty);
  });

  test('close shows closed at once and stays closed on Ok', () async {
    await start();
    final gate = Completer<void>();
    fake.onClose = (id) async {
      await gate.future;
      return fake.serverClose(id);
    };
    final f = n.close('m1');
    await turn();
    expect(st(c, 'm1').closed, isTrue);
    gate.complete();
    expect(await f, isA<Ok<void>>());
    expect(st(c, 'm1').closed, isTrue);
    expect(fake.closeCalls, ['m1']);
  });

  test('a refused close reopens the poll', () async {
    await start();
    final gate = Completer<void>();
    fake.onClose = (id) async {
      await gate.future;
      return const Err(DeniedFailure());
    };
    final f = n.close('m1');
    await turn();
    expect(st(c, 'm1').closed, isTrue);
    gate.complete();
    expect(failureOf(await f), isA<DeniedFailure>());
    expect(st(c, 'm1').closed, isFalse);
  });

  test('another member\'s vote arrives live; mine is kept', () async {
    await start();
    await n.vote('m1', {'a'});
    fake.others('m1', 'u3', {'b'});
    await until(() => st(c, 'm1').options[1].votes == 1);
    await until(() => st(c, 'm1').voters == 2);
    expect(st(c, 'm1').mine, {'a'});
    expect(st(c, 'm1').options[0].votes, 1);
  });

  test('a poll closed by its creator arrives live', () async {
    await start();
    fake.serverClose('m2', 'u2');
    await until(() => st(c, 'm2').closed);
  });

  test('ensure fetches a missing poll once; force fetches again', () async {
    await start();
    fake.seed('c1', poll('m9'));
    expect(c.read(pollsProvider).value!['m9'], isNull);
    await n.ensure('m9');
    expect(st(c, 'm9').question, 'Lunch?');
    final k = fake.pollCalls.length;
    expect(fake.pollCalls, contains('m9'));
    await n.ensure('m9');
    expect(fake.pollCalls.length, k);
    fake.others('m9', 'u3', {'a'});
    await n.ensure('m9', force: true);
    expect(fake.pollCalls.length, k + 1);
    expect(st(c, 'm9').options[0].votes, 1);
  });

  test('addLocal shows the poll at once', () async {
    await start();
    n.addLocal(poll('m7'));
    expect(c.read(pollsProvider).value!['m7'], isNotNull);
  });

  test(
    'pollVotesProvider lists voters; anonymous only mine; Err throws',
    () async {
      fake = PollFake()
        ..seed(
          'c1',
          poll('m1'),
          ballots: {
            'u2': {'a'},
            'u3': {'b'},
          },
        )
        ..seed(
          'c1',
          poll('m4', anonymous: true),
          ballots: {
            'u2': {'a'},
            'u1': {'b'},
          },
        );
      c = await ready(fake);
      c.listen(pollVotesProvider('m1'), (_, _) {});
      final v = await c.read(pollVotesProvider('m1').future);
      expect(
        {for (final x in v) (x.userId, x.optionId)},
        {('u2', 'a'), ('u3', 'b')},
      );
      c.listen(pollVotesProvider('m4'), (_, _) {});
      final a = await c.read(pollVotesProvider('m4').future);
      expect(a.map((x) => x.userId), ['u1']);
      fake.onVoters = (id) async => const Err(DeniedFailure());
      c.invalidate(pollVotesProvider('m1'));
      await expectLater(
        c.read(pollVotesProvider('m1').future),
        throwsA(isA<DeniedFailure>()),
      );
    },
  );
}
