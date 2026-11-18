import 'package:flutter_test/flutter_test.dart';

import '../../support/invite_ui_world.dart';

import 'package:sis/core/failure.dart';

void main() {
  group('invite create failures', () {
    testWidgets(
      'no link: Create link fails (server) shows the error box with Try again',
      (t) async {
        final w = InviteWorld();
        await openGroupPage(t, w);
        await tapKey(t, 'setting-invite-link');
        expect(byKey('invite-create'), findsOneWidget);
        w.invite.failNext = const DeniedFailure();
        await tapKey(t, 'invite-create');
        expect(byKey('invite-error-box'), findsOneWidget);
        expect(byKey('invite-retry'), findsOneWidget);
        expect(byKey('invite-link-text'), findsNothing);
        await t.pump(const Duration(seconds: 30));
      },
    );

    testWidgets(
      'no link: Create link fails (offline) shows the offline box with Try again',
      (t) async {
        final w = InviteWorld();
        await openGroupPage(t, w);
        await tapKey(t, 'setting-invite-link');
        expect(byKey('invite-create'), findsOneWidget);
        w.invite.failNext = const NetworkFailure(
          'No connection',
          retryable: true,
        );
        await tapKey(t, 'invite-create');
        expect(byKey('invite-offline-box'), findsOneWidget);
        expect(byKey('invite-link-text'), findsNothing);
        await t.pump(const Duration(seconds: 30));
      },
    );

    testWidgets('expired link: Create new link fails (server)', (t) async {
      final w = InviteWorld();
      await t.runAsync(() => w.invite.resetInviteLink('g1', validDays: 7));
      w.invite.expire('g1');
      await openGroupPage(t, w);
      await tapKey(t, 'setting-invite-link');
      expect(byKey('invite-create-new'), findsOneWidget);
      w.invite.failNext = const DeniedFailure();
      await tapKey(t, 'invite-create-new');
      expect(byKey('invite-error-box'), findsOneWidget);
      expect(byKey('invite-retry'), findsOneWidget);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('expired link: Create new link fails (offline)', (t) async {
      final w = InviteWorld();
      await t.runAsync(() => w.invite.resetInviteLink('g1', validDays: 7));
      w.invite.expire('g1');
      await openGroupPage(t, w);
      await tapKey(t, 'setting-invite-link');
      expect(byKey('invite-create-new'), findsOneWidget);
      w.invite.failNext = const NetworkFailure(
        'No connection',
        retryable: true,
      );
      await tapKey(t, 'invite-create-new');
      expect(byKey('invite-offline-box'), findsOneWidget);
      await t.pump(const Duration(seconds: 30));
    });
  });
}
