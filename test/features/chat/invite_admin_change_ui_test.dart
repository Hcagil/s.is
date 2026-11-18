import 'package:flutter_test/flutter_test.dart';

import '../../support/invite_ui_world.dart';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/invite_link.dart';

void main() {
  group('invite admin changes', () {
    testWidgets('the time sheet changes the limit and keeps the same link', (
      t,
    ) async {
      final w = InviteWorld();
      await t.runAsync(() => w.invite.resetInviteLink('g1', validDays: 7));
      final oldLink = await t.runAsync(() => w.invite.inviteLink('g1'));
      final oldToken = ((oldLink as Ok).value as InviteLink).token;
      await openGroupPage(t, w);
      await tapKey(t, 'setting-invite-link');

      final before = w.invite.calls.length;
      await tapKey(t, 'invite-time');
      expect(byKey('invite-time-card'), findsOneWidget);
      await tapKey(t, 'invite-time-30');
      await tapKey(t, 'invite-time-save');

      final afterCalls = w.invite.calls.skip(before).toList();
      expect(afterCalls.where((c) => c.startsWith('expiry:g1:')).length, 1);
      expect(afterCalls.where((c) => c.startsWith('reset')).isEmpty, true);

      final linkResult = await t.runAsync(() => w.invite.inviteLink('g1'));
      expect(linkResult, isA<Ok>());
      final link = (linkResult as Ok).value as InviteLink;
      final token = link.token;
      expect(link.validDays, 30);
      expect(token, oldToken);
      expect(find.textContaining(token), findsWidgets);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('reset asks first: cancel does nothing', (t) async {
      final w = InviteWorld();
      await t.runAsync(() => w.invite.resetInviteLink('g1', validDays: 7));
      await openGroupPage(t, w);
      await tapKey(t, 'setting-invite-link');

      final before = w.invite.calls.length;
      await tapKey(t, 'invite-reset');
      expect(byKey('invite-confirm'), findsOneWidget);
      expect(
        w.invite.calls.skip(before).where((c) => c.startsWith('reset')).isEmpty,
        true,
      );
      await tapKey(t, 'invite-confirm-cancel');
      expect(byKey('invite-confirm'), findsNothing);
      expect(
        w.invite.calls.skip(before).where((c) => c.startsWith('reset')).isEmpty,
        true,
      );

      final linkResult = await t.runAsync(() => w.invite.inviteLink('g1'));
      expect(linkResult, isA<Ok>());
      final link = (linkResult as Ok).value as InviteLink;
      final token = link.token;
      expect(find.textContaining(token), findsWidgets);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('reset after confirm makes a new link', (t) async {
      final w = InviteWorld();
      await t.runAsync(() => w.invite.resetInviteLink('g1', validDays: 7));
      await openGroupPage(t, w);
      await tapKey(t, 'setting-invite-link');

      final before = w.invite.calls.length;
      await tapKey(t, 'invite-reset');
      await tapKey(t, 'invite-confirm-ok');

      final afterCalls = w.invite.calls.skip(before).toList();
      expect(afterCalls.where((c) => c.startsWith('reset:g1:7')).length, 1);

      final linkResult = await t.runAsync(() => w.invite.inviteLink('g1'));
      expect(linkResult, isA<Ok>());
      final link = (linkResult as Ok).value as InviteLink;
      final newToken = link.token;
      expect(find.textContaining(newToken), findsWidgets);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('turn off asks first and then removes the link', (t) async {
      final w = InviteWorld();
      await t.runAsync(() => w.invite.resetInviteLink('g1', validDays: 7));
      await openGroupPage(t, w);
      await tapKey(t, 'setting-invite-link');

      final before = w.invite.calls.length;
      await tapKey(t, 'invite-turn-off');
      expect(byKey('invite-confirm'), findsOneWidget);
      expect(
        w.invite.calls.skip(before).where((c) => c.startsWith('off')).isEmpty,
        true,
      );
      await tapKey(t, 'invite-confirm-ok');

      final afterCalls = w.invite.calls.skip(before).toList();
      expect(afterCalls.where((c) => c.startsWith('off:g1')).length, 1);
      expect(byKey('invite-create'), findsOneWidget);
      expect(byKey('invite-link-text'), findsNothing);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('a failed change keeps the old link and shows a red box', (
      t,
    ) async {
      final w = InviteWorld();
      await t.runAsync(() => w.invite.resetInviteLink('g1', validDays: 7));
      await openGroupPage(t, w);
      await tapKey(t, 'setting-invite-link');

      final oldLinkResult = await t.runAsync(() => w.invite.inviteLink('g1'));
      final oldToken = (oldLinkResult as Ok).value as InviteLink;
      w.invite.failNext = const DeniedFailure();

      await tapKey(t, 'invite-reset');
      await tapKey(t, 'invite-confirm-ok');

      expect(byKey('invite-error-box'), findsOneWidget);
      expect(byKey('invite-link-text'), findsOneWidget);
      expect(find.textContaining(oldToken.token), findsWidgets);

      final newLinkResult = await t.runAsync(() => w.invite.inviteLink('g1'));
      final newToken = (newLinkResult as Ok).value as InviteLink;
      expect(newToken.token, oldToken.token);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets(
      'offline: a failed change shows the offline box and keeps the link',
      (t) async {
        final w = InviteWorld();
        await t.runAsync(() => w.invite.resetInviteLink('g1', validDays: 7));
        await openGroupPage(t, w);
        await tapKey(t, 'setting-invite-link');

        final oldLinkResult = await t.runAsync(() => w.invite.inviteLink('g1'));
        final oldToken = (oldLinkResult as Ok).value as InviteLink;
        w.invite.failNext = const NetworkFailure(
          'No connection',
          retryable: true,
        );

        await tapKey(t, 'invite-reset');
        await tapKey(t, 'invite-confirm-ok');

        expect(byKey('invite-offline-box'), findsOneWidget);
        expect(find.textContaining(oldToken.token), findsWidgets);

        final newLinkResult = await t.runAsync(() => w.invite.inviteLink('g1'));
        final newToken = (newLinkResult as Ok).value as InviteLink;
        expect(newToken.token, oldToken.token);
      },
    );
  });
}
