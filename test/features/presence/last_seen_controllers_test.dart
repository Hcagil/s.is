// lastSeenProvider and lastSeenReporterProvider, written from the contract,
// against a presence fake that answers like last_seen_of: mutual (nothing
// while the caller hides their own), a snapshot of the server when the query
// ran, and a failure when told to. The seam to the real database is
// test/integration/last_seen_integration_test.dart.
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

OwnProfile profile({bool lastSeen = true}) => OwnProfile(
  userId: 'u1',
  displayName: 'Maya',
  tag: 'maya',
  onboardingDone: true,
  shareLastSeen: lastSeen,
);

final bobSeen = DateTime.utc(2026, 9, 23, 10, 15);
final bobSeenLater = DateTime.utc(2026, 9, 23, 11, 40);

/// The wiring production mounts, with every repository faked. The presence
/// fake reads the caller's sharing from the same profile row the controller
/// saves to, as the server does.
({ProviderContainer c, PresenceFake presence, ProfileFake p}) scope({
  bool shareLastSeen = true,
}) {
  final p = ProfileFake(profile: profile(lastSeen: shareLastSeen));
  final presence = PresenceFake(owner: p);
  final c = ProviderContainer.test(
    overrides: [
      presenceRepositoryProvider.overrideWithValue(presence),
      profileRepositoryProvider.overrideWithValue(p),
      chatRepositoryProvider.overrideWithValue(ChatFake()),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  c.listen(ownProfileProvider, (_, _) {});
  return (c: c, presence: presence, p: p);
}

Future<void> flush(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(Duration.zero);
  }
}

int asked(PresenceFake f, String id) =>
    f.calls.where((c) => c == 'lastSeen:$id').length;

/// The provider's settled value; fails the test on a loading or error state.
DateTime? value(ProviderContainer c, String id) {
  final s = c.read(lastSeenProvider(id));
  expect(s.hasError, isFalse, reason: 'last seen surfaced an error');
  expect(s.hasValue, isTrue, reason: 'last seen never settled');
  return s.value;
}

void main() {
  group('lastSeenProvider', () {
    testWidgets('answers with the repository\'s time for that member', (
      t,
    ) async {
      final w = scope();
      w.presence.lastSeen
        ..['u2'] = bobSeen
        ..['u3'] = bobSeenLater;
      w.c.listen(lastSeenProvider('u2'), (_, _) {});
      await flush(t);

      expect(value(w.c, 'u2'), bobSeen);
      expect(asked(w.presence, 'u2'), greaterThanOrEqualTo(1));
      expect(asked(w.presence, 'u3'), 0, reason: 'asked about someone else');
    });

    testWidgets('a member the server knows nothing about is null', (t) async {
      final w = scope();
      w.c.listen(lastSeenProvider('u2'), (_, _) {});
      await flush(t);
      expect(value(w.c, 'u2'), isNull);
    });

    testWidgets('a failed lookup is null, never an error', (t) async {
      final w = scope();
      w.presence
        ..lastSeen['u2'] = bobSeen
        ..lastSeenResult = const Err(NetworkFailure('no route to host'));
      w.c.listen(lastSeenProvider('u2'), (_, _) {});
      await flush(t);
      expect(value(w.c, 'u2'), isNull);

      w.presence.lastSeenResult = const Err(DeniedFailure());
      w.c.invalidate(lastSeenProvider('u2'));
      await flush(t);
      expect(value(w.c, 'u2'), isNull);
    });

    testWidgets('asks again when that member goes offline', (t) async {
      final w = scope();
      w.presence.setOthersOnline({'u2'});
      w.c.listen(lastSeenProvider('u2'), (_, _) {});
      await flush(t);
      expect(value(w.c, 'u2'), isNull, reason: 'bob has no time stored yet');
      final before = asked(w.presence, 'u2');

      // Bob's app reports him seen as it goes to the background.
      w.presence.lastSeen['u2'] = bobSeen;
      w.presence.setOthersOnline({});
      await flush(t);

      expect(asked(w.presence, 'u2'), greaterThan(before));
      expect(
        value(w.c, 'u2'),
        bobSeen,
        reason: 'bob went offline and the old answer is still shown',
      );
    });

    testWidgets('an answer to an older question never replaces a newer one', (
      t,
    ) async {
      final w = scope();
      w.presence
        ..setOthersOnline({'u2'})
        ..lastSeen['u2'] = bobSeen
        ..holdLastSeen();
      w.c.listen(lastSeenProvider('u2'), (_, _) {});
      await flush(t);

      // While that lookup is in flight bob comes back, goes again, and the
      // server now holds a later time.
      w.presence.lastSeen['u2'] = bobSeenLater;
      w.presence.setOthersOnline({});
      await flush(t);
      w.presence.releaseLastSeen();
      await flush(t);

      expect(asked(w.presence, 'u2'), greaterThanOrEqualTo(2));
      expect(value(w.c, 'u2'), bobSeenLater);
    });

    testWidgets('asks again when the member turns their own sharing off and '
        'on: last seen is mutual', (t) async {
      final w = scope();
      w.presence.lastSeen['u2'] = bobSeen;
      w.c.listen(lastSeenProvider('u2'), (_, _) {});
      await flush(t);
      expect(value(w.c, 'u2'), bobSeen);
      final atStart = asked(w.presence, 'u2');

      final off = await w.c
          .read(ownProfileProvider.notifier)
          .setSharing(lastSeen: false);
      expect(off, isA<Ok<OwnProfile>>());
      await flush(t);
      expect(
        value(w.c, 'u2'),
        isNull,
        reason: 'hiding your own last seen hides everyone else\'s',
      );
      final whileOff = asked(w.presence, 'u2');
      expect(whileOff, greaterThan(atStart));

      await w.c.read(ownProfileProvider.notifier).setSharing(lastSeen: true);
      await flush(t);
      expect(value(w.c, 'u2'), bobSeen);
      expect(asked(w.presence, 'u2'), greaterThan(whileOff));
    });

    testWidgets('a member who does not share sees nobody\'s time', (t) async {
      final w = scope(shareLastSeen: false);
      w.presence.lastSeen['u2'] = bobSeen;
      w.c.listen(lastSeenProvider('u2'), (_, _) {});
      await flush(t);
      expect(value(w.c, 'u2'), isNull);
    });
  });

  group('lastSeenReporterProvider', () {
    testWidgets('reports the member seen through the repository', (t) async {
      final w = scope();
      await flush(t);
      final report = w.c.read(lastSeenReporterProvider);
      final done = report();
      await flush(t);
      await done;

      expect(w.presence.touches, 1);
      expect(w.presence.lastSeen['u1'], isNotNull);
    });

    testWidgets('a refused report does not throw', (t) async {
      final w = scope();
      w.presence.touchResult = const Err(DeniedFailure());
      await flush(t);
      final done = w.c.read(lastSeenReporterProvider)();
      await flush(t);
      await expectLater(done, completes);
      expect(w.presence.touches, 1);
    });
  });
}
