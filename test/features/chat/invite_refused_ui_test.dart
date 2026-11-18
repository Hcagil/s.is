import 'package:flutter_test/flutter_test.dart';

import '../../support/l10n.dart';
import '../../support/invite_ui_world.dart';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/invite_link.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';

Future<String> seed(WidgetTester t, InviteWorld w, String conv) async {
  await t.runAsync(() => w.invite.resetInviteLink(conv));
  return (((await t.runAsync(() => w.invite.inviteLink(conv))) as Ok).value
          as InviteLink)
      .token;
}

Future<void> paste(WidgetTester t, InviteWorld w, String text) async {
  await pumpApp(t, w);
  await openNewChat(t);
  await tapKey(t, 'join-with-link');
  await t.enterText(byKey('join-link-field'), text);
  await settle(t);
  await tapKey(t, 'join-link-continue');
}

void main() {
  group('refused links', () {
    testWidgets('an unknown link shows the invalid page', (t) async {
      final w = InviteWorld();
      await paste(t, w, 'zzzzzzzzzzzzzzzzzzzzzzzz');
      expect(byKey('invite-refused-page'), findsOneWidget);
      expect(find.text(l10nEn.inviteInvalidTitle), findsOneWidget);
      expect(w.invite.calls.where((c) => c.startsWith('join')).isEmpty, isTrue);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('an expired link shows the same invalid page', (t) async {
      final w = InviteWorld();
      final token = await seed(t, w, 'g2');
      w.invite.expire('g2');
      await paste(t, w, token);
      expect(byKey('invite-refused-page'), findsOneWidget);
      expect(find.text(l10nEn.inviteInvalidTitle), findsOneWidget);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('a closed group shows the closed page', (t) async {
      final w = InviteWorld();
      final token = await seed(t, w, 'g2');
      w.invite.closedGroups.add('g2');
      await paste(t, w, token);
      expect(byKey('invite-refused-page'), findsOneWidget);
      expect(find.text(l10nEn.inviteClosedBody), findsOneWidget);
      expect(find.text(l10nEn.inviteInvalidTitle), findsNothing);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('a removed person sees the removed page', (t) async {
      final w = InviteWorld();
      final token = await seed(t, w, 'g2');
      w.invite.removedFrom.add('g2');
      await paste(t, w, token);
      expect(find.text(l10nEn.inviteRemovedTitle), findsOneWidget);
      expect(find.text(l10nEn.inviteRemovedBody), findsOneWidget);
      expect(w.invite.calls.where((c) => c.startsWith('join')).isEmpty, isTrue);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('OK closes the refused page', (t) async {
      final w = InviteWorld();
      await paste(t, w, 'zzzzzzzzzzzzzzzzzzzzzzzz');
      await tapKey(t, 'invite-refused-ok');
      await t.pump(const Duration(seconds: 1));
      expect(byKey('invite-refused-page'), findsNothing);
      await t.pump(const Duration(seconds: 30));
    });
  });

  group('joined line in the group timeline', () {
    testWidgets('a joined-by-link event shows its line', (t) async {
      final w = InviteWorld();
      w.invite.joinEventList['g1'] = [
        GroupEvent(
          id: 'j1',
          conversationId: 'g1',
          kind: GroupEventKind.joined,
          subjectId: 'ub',
          actorId: 'ub',
          createdAt: DateTime.utc(2026, 9, 19, 12),
        ),
      ];
      await pumpApp(t, w);
      await openChat(t, 'g1');
      expect(find.text(l10nEn.eventJoinedByLink('Bob Stone')), findsOneWidget);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('no events: no joined line', (t) async {
      final w = InviteWorld();
      await pumpApp(t, w);
      await openChat(t, 'g1');
      expect(find.textContaining('via invite link'), findsNothing);
      expect(find.byType(MessageScreen), findsOneWidget);
      await t.pump(const Duration(seconds: 30));
    });
  });
}
