import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/badge_controller.dart';
import 'package:sis/features/notifications/domain/push.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

/// The icon, as the platform would hold it: every number set, in order.
class BadgeFake implements AppBadge {
  final sets = <int>[];
  @override
  Future<void> set(int count) async => sets.add(count);
}

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

class _SignedOut extends SessionController {
  @override
  Future<SessionState> build() async => const SignedOut();
}

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('badgeSyncProvider archived behavior', () {
    late ChatFake chat;
    late BadgeFake badge;

    Future<ProviderContainer> mount({
      bool signedIn = true,
      bool settledFirst = true,
    }) async {
      final c = ProviderContainer.test(
        overrides: [
          chatRepositoryProvider.overrideWithValue(chat),
          appBadgeProvider.overrideWithValue(badge),
          sessionControllerProvider.overrideWith(
            signedIn ? _SignedIn.new : _SignedOut.new,
          ),
        ],
      );
      // The session has answered (a resumed app); the cold start where it
      // has not yet is its own test below.
      if (settledFirst) {
        c.listen(currentUserIdProvider, (_, _) {});
        await c.read(sessionControllerProvider.future);
        await wait(10);
      }
      // Mounted as SisApp mounts both: the list is shown, the sync listened.
      c.listen(conversationListProvider, (_, _) {});
      c.listen(badgeSyncProvider, (_, _) {});
      return c;
    }

    int reads() => chat.calls.where((x) => x == 'unreadTotal').length;

    setUp(() {
      chat = ChatFake(self: me.userId, latency: const Duration(milliseconds: 2))
        ..conversationsResult = const Ok([
          Conversation(id: 'c1', title: 'Crew', unread: 2, archived: true),
          Conversation(id: 'c2', title: 'Work', unread: 3),
        ])
        ..unreadTotalResult = const Ok(7);
      badge = BadgeFake();
    });

    test('message in archived chat does not trigger a read', () async {
      final c = await mount();
      await wait(1600); // allow initial read and debounce
      expect(badge.sets, [7]);
      final initialReads = reads();

      // Deliver a message into the archived chat c1
      chat.deliver(
        Message(
          id: 'm1',
          conversationId: 'c1',
          senderId: 'u2',
          body: 'hey',
          createdAt: DateTime.now(),
        ),
      );

      await wait(1600); // wait past debounce
      expect(badge.sets, [7]); // still only the initial set
      expect(reads(), initialReads); // no new read
      c.dispose();
    });

    test('message in non-archived chat triggers a read', () async {
      final c = await mount();
      await wait(1600); // allow initial read and debounce
      expect(badge.sets, [7]);
      final initialReads = reads();

      // Update the unreadTotal to a new value before the next read
      chat.unreadTotalResult = const Ok(8);

      // Deliver a message into the non-archived chat c2
      chat.deliver(
        Message(
          id: 'm2',
          conversationId: 'c2',
          senderId: 'u3',
          body: 'hello',
          createdAt: DateTime.now(),
        ),
      );

      await wait(1600); // wait past debounce
      expect(badge.sets, [7, 8]); // new total set
      expect(reads(), initialReads + 1); // one additional read
      c.dispose();
    });
  });
}
