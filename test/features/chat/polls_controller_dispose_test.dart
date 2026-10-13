// PollsController (pollsProvider) when it goes away mid-flight, against
// PollFake -- never the SDK. Leaving the chat (or switching) while the
// post-join re-fetch is still out must not touch the disposed provider.

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

  test(
    'leaving the chat while the re-fetch is in flight throws nothing',
    () async {
      final gate = Completer<void>();
      fake = PollFake()..seed('c1', poll('m1'));
      fake.onLoad = (cid, k) async {
        if (k >= 2) await gate.future;
        return Ok([if (cid == 'c1') fake.view('m1')!]);
      };
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
      await until(() => fake.loadCalls.length >= 2);
      c.read(openConversationProvider.notifier).open('c2');
      await turn();
      gate.complete();
      await turn();
      await turn();
      expect(c.read(pollsProvider).value?['m1'], isNull);
    },
  );

  test(
    'leaving the chat screen (polls disposed) mid re-fetch throws nothing',
    () async {
      final gate = Completer<void>();
      fake = PollFake()..seed('c1', poll('m1'));
      fake.onLoad = (cid, k) async {
        if (k >= 2) await gate.future;
        return Ok([fake.view('m1')!]);
      };
      final c = ProviderContainer(
        overrides: [
          chatRepositoryProvider.overrideWithValue(ChatFake()),
          pollRepositoryProvider.overrideWithValue(fake),
          sessionControllerProvider.overrideWith(_SignedIn.new),
        ],
      );
      await settled(c);
      final sub = c.listen(pollsProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open('c1');
      await until(() => fake.loadCalls.length >= 2);
      sub.close(); // autoDispose: no listener left, as when the screen closes
      await turn();
      await turn();
      expect(c.exists(pollsProvider), isFalse);
      gate.complete();
      await turn();
      await turn();
      c.dispose();
    },
  );
}
