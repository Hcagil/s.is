// Controller tests for online status and typing, written from the contract:
// what the providers expose and what the repository is asked to do, against
// a fake that joins late, refuses, and keeps announcing a channel nobody let
// go of. Time is the test binding's fake clock, so the linger and throttle
// windows are exact rather than slept through.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

OwnProfile profile({bool presence = true, bool typing = true}) => OwnProfile(
  userId: 'u1',
  displayName: 'Maya',
  tag: 'maya',
  onboardingDone: true,
  sharePresence: presence,
  shareTyping: typing,
);

/// The wiring production mounts, with every repository faked. The session
/// gate watches the profile before home is ever shown, so it is watched here.
ProviderContainer scope(PresenceFake presence, ProfileFake p) {
  final c = ProviderContainer.test(
    overrides: [
      presenceRepositoryProvider.overrideWithValue(presence),
      profileRepositoryProvider.overrideWithValue(p),
      chatRepositoryProvider.overrideWithValue(ChatFake()),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  c.listen(ownProfileProvider, (_, _) {});
  return c;
}

/// Runs out every linger window, so no timer outlives the test.
Future<void> drain(WidgetTester t) => t.pump(typingLinger * 2);

/// Lets the fakes' async hops and the controllers' reactions run, without
/// moving the clock by any amount a linger or throttle would notice.
Future<void> flush(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(Duration.zero);
  }
}

void main() {
  group('online members', () {
    testWidgets('nothing is joined before the profile is known', (t) async {
      final presence = PresenceFake();
      final p = ProfileFake(profile: profile())..holdLoad();
      final c = scope(presence, p);
      c.listen(onlineMembersProvider, (_, _) {});
      await flush(t);

      expect(c.read(onlineMembersProvider), isEmpty);
      expect(
        presence.calls,
        isEmpty,
        reason: 'the sharing choice is unknown until the profile loads',
      );

      p.releaseLoad();
      await flush(t);
      expect(presence.calls, ['online:share']);

      presence.setOthersOnline({'u2'});
      await flush(t);
      expect(c.read(onlineMembersProvider), contains('u2'));
    });

    testWidgets('a member who does not share joins hidden and still sees '
        'others', (t) async {
      final presence = PresenceFake()..setOthersOnline({'u2'});
      final c = scope(presence, ProfileFake(profile: profile(presence: false)));
      c.listen(onlineMembersProvider, (_, _) {});
      await flush(t);

      expect(presence.calls, ['online:hidden']);
      expect(presence.announcing, isEmpty);
      expect(c.read(onlineMembersProvider), {'u2'});
    });

    testWidgets('every arrival and departure is reflected', (t) async {
      final presence = PresenceFake();
      final c = scope(presence, ProfileFake(profile: profile()));
      c.listen(onlineMembersProvider, (_, _) {});
      await flush(t);

      presence.setOthersOnline({'u2'});
      await flush(t);
      expect(c.read(onlineMembersProvider), containsAll(['u2']));

      presence.setOthersOnline({'u2', 'u3'});
      await flush(t);
      expect(c.read(onlineMembersProvider), containsAll(['u2', 'u3']));

      presence.setOthersOnline({'u3'});
      await flush(t);
      expect(c.read(onlineMembersProvider), isNot(contains('u2')));
      expect(c.read(onlineMembersProvider), contains('u3'));
    });

    testWidgets('turning sharing off rejoins hidden and leaves the sharing '
        'channel; turning it on announces again', (t) async {
      final presence = PresenceFake()..setOthersOnline({'u2'});
      final p = ProfileFake(profile: profile());
      final c = scope(presence, p);
      c.listen(onlineMembersProvider, (_, _) {});
      await flush(t);
      expect(presence.announcing, hasLength(1));

      await c.read(ownProfileProvider.notifier).setSharing(presence: false);
      await flush(t);

      expect(presence.calls, ['online:share', 'online:hidden']);
      expect(
        presence.announcing,
        isEmpty,
        reason: 'the old channel still announces a member who opted out',
      );
      expect(presence.live, hasLength(1), reason: 'channels leaked');
      expect(c.read(onlineMembersProvider), contains('u2'));

      await c.read(ownProfileProvider.notifier).setSharing(presence: true);
      await flush(t);
      expect(presence.calls.last, 'online:share');
      expect(presence.announcing, hasLength(1));
      expect(presence.live, hasLength(1), reason: 'channels leaked');
    });

    testWidgets('a join refused by the server is an empty set, not an error', (
      t,
    ) async {
      final presence = PresenceFake()
        ..onlineRefusal = const DeniedFailure()
        ..setOthersOnline({'u2'});
      final c = scope(presence, ProfileFake(profile: profile()));
      c.listen(onlineMembersProvider, (_, _) {});
      await flush(t);

      expect(presence.calls, ['online:share']);
      expect(() => c.read(onlineMembersProvider), returnsNormally);
      expect(c.read(onlineMembersProvider), isEmpty);
    });

    testWidgets('a sharing join still pending when sharing is turned off is '
        'torn down when it lands', (t) async {
      final presence = PresenceFake()
        ..setOthersOnline({'u2'})
        ..holdOnline();
      final p = ProfileFake(profile: profile());
      final c = scope(presence, p);
      c.listen(onlineMembersProvider, (_, _) {});
      await flush(t);
      expect(presence.joins, hasLength(1));

      await c.read(ownProfileProvider.notifier).setSharing(presence: false);
      await flush(t);
      expect(presence.joins, hasLength(2));

      presence.releaseOnline();
      await flush(t);

      expect(
        presence.announcing,
        isEmpty,
        reason: 'a join that landed after the rebuild is still announcing',
      );
      expect(presence.live, hasLength(1));
      expect(presence.live.single.share, isFalse);
      expect(c.read(onlineMembersProvider), contains('u2'));
    });

    testWidgets('a stale join that lands AFTER the current one neither '
        'announces nor takes over the state', (t) async {
      final presence = PresenceFake()..holdOnline();
      final p = ProfileFake(profile: profile());
      final c = scope(presence, p);
      c.listen(onlineMembersProvider, (_, _) {});
      await flush(t);
      await c.read(ownProfileProvider.notifier).setSharing(presence: false);
      await flush(t);
      final [stale, current] = presence.joins;

      presence.releaseJoin(current);
      await flush(t);
      presence.setOthersOnline({'u2'});
      await flush(t);
      expect(c.read(onlineMembersProvider), {'u2'});

      presence.releaseJoin(stale);
      await flush(t);
      expect(stale.left, isTrue, reason: 'the stale channel was never left');
      expect(presence.announcing, isEmpty);
      expect(c.read(onlineMembersProvider), {
        'u2',
      }, reason: 'the stale channel\'s view replaced the current one');
    });
    testWidgets('when nobody watches any more, the channel is left', (t) async {
      final presence = PresenceFake();
      final c = scope(presence, ProfileFake(profile: profile()));
      final sub = c.listen(onlineMembersProvider, (_, _) {});
      await flush(t);
      expect(presence.announcing, hasLength(1));

      sub.close();
      await flush(t);
      expect(presence.live, isEmpty);
    });
  });

  group('typing', () {
    Future<(ProviderContainer, PresenceFake, FakeTypingChannel)> openC1(
      WidgetTester t, {
      bool shareTyping = true,
    }) async {
      final presence = PresenceFake();
      final c = scope(
        presence,
        ProfileFake(profile: profile(typing: shareTyping)),
      );
      c.listen(typingProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open('c1');
      await flush(t);
      final channel = presence.typingIn('c1');
      expect(channel, isNotNull, reason: 'opening c1 joined no typing channel');
      return (c, presence, channel!);
    }

    testWidgets('no open conversation, no typing channel', (t) async {
      final presence = PresenceFake();
      final c = scope(presence, ProfileFake(profile: profile()));
      c.listen(typingProvider, (_, _) {});
      await flush(t);

      expect(c.read(typingProvider), isEmpty);
      expect(presence.calls.where((x) => x.startsWith('typing')), isEmpty);
      await drain(t);
    });

    testWidgets('a typist shows at once and lingers exactly typingLinger', (
      t,
    ) async {
      final (c, _, channel) = await openC1(t);
      channel.type('u2');
      await flush(t);
      expect(c.read(typingProvider), {'u2'});

      await t.pump(typingLinger - const Duration(milliseconds: 100));
      expect(c.read(typingProvider), {'u2'}, reason: 'expired too early');

      await t.pump(const Duration(milliseconds: 200));
      expect(c.read(typingProvider), isEmpty, reason: 'never expired');
      await drain(t);
    });

    testWidgets('a new signal restarts the linger', (t) async {
      final (c, _, channel) = await openC1(t);
      channel.type('u2');
      await flush(t);
      await t.pump(const Duration(seconds: 3));
      channel.type('u2');
      await flush(t);

      await t.pump(const Duration(seconds: 3)); // 6 s after the first
      expect(c.read(typingProvider), {'u2'}, reason: 'the first timer won');

      await t.pump(const Duration(milliseconds: 2100));
      expect(c.read(typingProvider), isEmpty);
      await drain(t);
    });

    testWidgets('typists expire independently', (t) async {
      final (c, _, channel) = await openC1(t);
      channel.type('u2');
      await t.pump(const Duration(seconds: 2));
      channel.type('u3');
      await flush(t);
      expect(c.read(typingProvider), {'u2', 'u3'});

      await t.pump(const Duration(milliseconds: 3100));
      expect(c.read(typingProvider), {'u3'});
      await t.pump(const Duration(seconds: 2));
      expect(c.read(typingProvider), isEmpty);
      await drain(t);
    });

    testWidgets('a message from a typist removes them at once and only them', (
      t,
    ) async {
      final (c, _, channel) = await openC1(t);
      channel
        ..type('u2')
        ..type('u3');
      await flush(t);

      c.read(typingProvider.notifier).messageFrom('u2');
      await flush(t);
      expect(c.read(typingProvider), {'u3'});

      c.read(typingProvider.notifier).messageFrom('u9');
      await flush(t);
      expect(c.read(typingProvider), {'u3'});
      await drain(t);
    });

    testWidgets('typing again after a message lingers the full window; the '
        'cleared timer does not cut it short', (t) async {
      final (c, _, channel) = await openC1(t);
      channel.type('u2');
      await flush(t);
      await t.pump(const Duration(seconds: 4));
      c.read(typingProvider.notifier).messageFrom('u2');
      await t.pump(const Duration(milliseconds: 500));
      channel.type('u2');
      await flush(t);

      await t.pump(const Duration(milliseconds: 700)); // past the first expiry
      expect(c.read(typingProvider), {'u2'});
      await t.pump(const Duration(milliseconds: 4400));
      expect(c.read(typingProvider), isEmpty);
      await drain(t);
    });

    // Real time, not the binding's fake clock: the throttle may measure the
    // wall clock, which a fake clock does not move. That is a legitimate
    // choice, so the test pays two real seconds rather than dictate it.
    test('signalTyping sends at most once per typingEvery', () async {
      final presence = PresenceFake();
      final c = scope(presence, ProfileFake(profile: profile()));
      c.listen(typingProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(ownProfileProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final channel = presence.typingIn('c1')!;
      final typing = c.read(typingProvider.notifier);

      for (var i = 0; i < 5; i++) {
        typing.signalTyping();
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(channel.signals, 1);

      await Future<void>.delayed(
        typingEvery - const Duration(milliseconds: 400),
      );
      typing.signalTyping();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(channel.signals, 1, reason: 'throttle window too short');

      await Future<void>.delayed(const Duration(milliseconds: 500));
      typing.signalTyping();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(channel.signals, 2, reason: 'never signals again');
    });

    testWidgets('with typing sharing off nothing is sent, and others are '
        'still seen', (t) async {
      final (c, _, channel) = await openC1(t, shareTyping: false);
      c.read(typingProvider.notifier).signalTyping();
      await t.pump(const Duration(seconds: 3));
      c.read(typingProvider.notifier).signalTyping();
      await flush(t);
      expect(channel.signals, 0);

      channel.type('u2');
      await flush(t);
      expect(c.read(typingProvider), {'u2'});
      await drain(t);
    });

    // Real time: a throttle on the wall clock would swallow the second
    // signal under a fake clock and let this pass for the wrong reason.
    test('turning typing sharing off mid-conversation silences the next '
        'signal', () async {
      final presence = PresenceFake();
      final c = scope(presence, ProfileFake(profile: profile()));
      c.listen(typingProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(ownProfileProvider.future);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      c.read(typingProvider.notifier).signalTyping();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      await c.read(ownProfileProvider.notifier).setSharing(typing: false);
      await Future<void>.delayed(
        typingEvery + const Duration(milliseconds: 200),
      );
      c.read(typingProvider.notifier).signalTyping();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final sent = presence.typingChannels.fold<int>(
        0,
        (n, ch) => n + ch.signals + ch.signalsAfterClose,
      );
      expect(sent, 1);
    });

    testWidgets('closing the conversation closes the channel and clears', (
      t,
    ) async {
      final (c, _, channel) = await openC1(t);
      channel.type('u2');
      await flush(t);

      c.read(openConversationProvider.notifier).close();
      await flush(t);
      expect(channel.closed, isTrue);
      expect(c.read(typingProvider), isEmpty);

      c.read(typingProvider.notifier).signalTyping();
      await flush(t);
      expect(channel.signals + channel.signalsAfterClose, 0);
      await drain(t);
    });

    testWidgets('switching conversations moves the channel', (t) async {
      final (c, presence, c1) = await openC1(t);
      c1.type('u2');
      await flush(t);

      c.read(openConversationProvider.notifier).open('c2');
      await flush(t);
      expect(c1.closed, isTrue);
      expect(presence.typingIn('c2'), isNotNull);
      expect(c.read(typingProvider), isEmpty, reason: 'c1 typist leaked');
      await drain(t);
    });

    testWidgets('a refused typing channel is an empty set and signalling is '
        'harmless', (t) async {
      final presence = PresenceFake()..typingRefusal = const DeniedFailure();
      final c = scope(presence, ProfileFake(profile: profile()));
      c.listen(typingProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open('c1');
      await flush(t);

      expect(presence.calls, contains('typing:c1'));
      expect(c.read(typingProvider), isEmpty);
      expect(
        () => c.read(typingProvider.notifier).signalTyping(),
        returnsNormally,
      );
      await flush(t);
      await drain(t);
    });

    testWidgets('a typing join still pending when the conversation closes is '
        'closed when it lands', (t) async {
      final presence = PresenceFake()..holdTyping();
      final c = scope(presence, ProfileFake(profile: profile()));
      c.listen(typingProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open('c1');
      await flush(t);

      c.read(openConversationProvider.notifier).close();
      await flush(t);
      presence.releaseTyping();
      await flush(t);

      expect(presence.typingChannels, hasLength(1));
      expect(presence.typingChannels.single.closed, isTrue);
      await drain(t);
    });

    testWidgets('disposal mid-linger closes the channel and no timer fires '
        'into a dead controller', (t) async {
      final (c, _, channel) = await openC1(t);
      channel.type('u2');
      await flush(t);

      c.dispose();
      await flush(t);
      expect(channel.closed, isTrue);
      await drain(t); // a stray timer would throw here
    });
  });
}
