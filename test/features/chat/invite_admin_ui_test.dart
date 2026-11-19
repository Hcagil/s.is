import 'package:flutter_test/flutter_test.dart';

import '../../support/l10n.dart';
import '../../support/invite_ui_world.dart';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/invite_link.dart';

void main() {
  group('invite admin page', () {
    testWidgets('an admin sees the Invite link row', (t) async {
      final w = InviteWorld();
      await openGroupPage(t, w);
      await reveal(t, byKey('setting-invite-link'));
      expect(byKey('setting-invite-link'), findsOneWidget);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('an ordinary member does not see the row', (t) async {
      final w = InviteWorld(admin: false);
      await openGroupPage(t, w);
      await reveal(t, byKey('setting-invite-link'));
      expect(byKey('setting-invite-link'), findsNothing);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('a closed group hides the row even for an admin', (t) async {
      final w = InviteWorld(closed: true);
      await openGroupPage(t, w);
      await reveal(t, byKey('setting-invite-link'));
      expect(byKey('setting-invite-link'), findsNothing);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('no link yet shows Create link and creating shows the link', (
      t,
    ) async {
      final w = InviteWorld();
      await openGroupPage(t, w);
      await tapKey(t, 'setting-invite-link');
      expect(byKey('group-invite-page'), findsOneWidget);
      expect(byKey('invite-create'), findsOneWidget);
      expect(byKey('invite-link-text'), findsNothing);
      expect(find.text(l10nEn.groupInviteNoneTitle), findsOneWidget);

      await tapKey(t, 'invite-create');
      expect(
        w.invite.calls.any((c) => c.startsWith('reset:g1')),
        isTrue,
        reason: 'resetInviteLink should have been called',
      );

      final linkResult = await t.runAsync(() => w.invite.inviteLink('g1'));
      expect(linkResult, isA<Ok<InviteLink?>>());
      final link = (linkResult as Ok<InviteLink?>).value!;
      expect(byKey('invite-link-text'), findsOneWidget);
      expect(find.textContaining(link.token), findsWidgets);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('an existing link shows its rows', (t) async {
      final w = InviteWorld();
      await t.runAsync(() => w.invite.resetInviteLink('g1', validDays: 7));
      await openGroupPage(t, w);
      await tapKey(t, 'setting-invite-link');

      final keys = [
        'invite-link-text',
        'invite-time',
        'invite-copy',
        'invite-share',
        'invite-reset',
        'invite-turn-off',
        'invite-valid-until',
      ];

      for (final key in keys) {
        expect(
          byKey(key),
          findsOneWidget,
          reason: 'key $key should be present',
        );
      }
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('a link with no time limit shows no valid-until line', (
      t,
    ) async {
      final w = InviteWorld();
      await t.runAsync(() => w.invite.resetInviteLink('g1')); // validDays null
      await openGroupPage(t, w);
      await tapKey(t, 'setting-invite-link');

      expect(byKey('invite-link-text'), findsOneWidget);
      expect(byKey('invite-valid-until'), findsNothing);
      await t.pump(const Duration(seconds: 30));
    });
  });
}
