import 'package:flutter_test/flutter_test.dart';

import '../../support/l10n.dart';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/invite_link.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';

import '../../support/invite_ui_world.dart';

Future<String> seed(WidgetTester t, InviteWorld w, String conv) async {
  await t.runAsync(() => w.invite.resetInviteLink(conv));
  final res = await t.runAsync(() => w.invite.inviteLink(conv));
  final link = (res as Ok).value as InviteLink;
  return link.token;
}

Future<void> paste(WidgetTester t, InviteWorld w, String text) async {
  await pumpApp(t, w);
  await openNewChat(t);
  await tapKey(t, 'join-with-link');
  expect(byKey('join-link-page'), findsOneWidget);
  await t.enterText(byKey('join-link-field'), text);
  await settle(t);
  await tapKey(t, 'join-link-continue');
}

void main() {
  group('join with a link', () {
    late InviteWorld w;
    setUp(() {
      w = InviteWorld();
    });

    testWidgets('text that is not a code shows an error and asks nothing', (
      t,
    ) async {
      await paste(t, w, 'hello there!');
      expect(find.text(l10nEn.joinLinkNotInvite), findsOneWidget);
      expect(
        w.invite.calls.where((c) => c.startsWith('preview')).isEmpty,
        true,
      );
      expect(byKey('invite-join-page'), findsNothing);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('a valid link shows the preview', (t) async {
      w.invite.titles['g2'] = 'Chess club';
      w.invite.members['g2'] = 5;
      final token = await seed(t, w, 'g2');
      await paste(t, w, token);
      expect(byKey('invite-join-page'), findsOneWidget);
      expect(find.text('Chess club'), findsWidgets);
      expect(
        find.descendant(
          of: byKey('invite-group-count'),
          matching: find.textContaining('5'),
          matchRoot: true,
        ),
        findsWidgets,
      );
      expect(byKey('invite-join-button'), findsOneWidget);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('history on', (t) async {
      w.invite.titles['g2'] = 'Chess club';
      w.invite.members['g2'] = 5;
      w.invite.seeHistory['g2'] = true;
      final token = await seed(t, w, 'g2');
      await paste(t, w, token);
      expect(find.text(l10nEn.addMembersOldHint), findsOneWidget);
      expect(byKey('invite-join-history'), findsOneWidget);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('history off', (t) async {
      w.invite.titles['g2'] = 'Chess club';
      w.invite.members['g2'] = 5;
      w.invite.seeHistory['g2'] = false;
      final token = await seed(t, w, 'g2');
      await paste(t, w, token);
      expect(find.text(l10nEn.inviteJoinNoHistory), findsOneWidget);
      expect(find.text(l10nEn.addMembersOldHint), findsNothing);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('history unknown: no history line', (t) async {
      w.invite.titles['g2'] = 'Chess club';
      w.invite.members['g2'] = 5;
      // seeHistory stays null
      final token = await seed(t, w, 'g2');
      await paste(t, w, token);
      expect(byKey('invite-join-history'), findsNothing);
      expect(byKey('invite-join-button'), findsOneWidget);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('Join joins and opens the group with a toast', (t) async {
      w.invite.titles['g2'] = 'Chess club';
      w.invite.members['g2'] = 5;
      final token = await seed(t, w, 'g2');
      await paste(t, w, token);
      await tapKey(t, 'invite-join-button');
      expect(w.invite.calls.contains('join:$token'), true);
      expect(find.text(l10nEn.inviteJoinedToast), findsOneWidget);
      expect(containerOf(t).read(openConversationProvider), equals('g2'));
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('already a member: Go to group opens the group', (t) async {
      final token = await seed(t, w, 'g1');
      await paste(t, w, token);
      expect(byKey('invite-already-page'), findsOneWidget);
      expect(find.text(l10nEn.inviteAlreadyTitle), findsOneWidget);
      expect(w.invite.calls.where((c) => c.startsWith('join')).isEmpty, true);
      await tapKey(t, 'invite-open-group');
      expect(find.byType(MessageScreen), findsOneWidget);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('a failed join shows the error and no toast', (t) async {
      w.invite.titles['g2'] = 'Chess club';
      w.invite.members['g2'] = 5;
      final token = await seed(t, w, 'g2');
      await paste(t, w, token);
      w.invite.failNext = const DeniedFailure();
      await tapKey(t, 'invite-join-button');
      expect(byKey('invite-join-error'), findsOneWidget);
      expect(find.text(l10nEn.inviteJoinedToast), findsNothing);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('offline Continue shows the offline error on the paste page', (
      t,
    ) async {
      w.invite.titles['g2'] = 'Chess club';
      w.invite.members['g2'] = 5;
      final token = await seed(t, w, 'g2');
      w.invite.failNext = const NetworkFailure(
        'No connection',
        retryable: true,
      );
      await paste(t, w, token);
      expect(find.text(l10nEn.joinLinkOffline), findsOneWidget);
      expect(byKey('invite-join-page'), findsNothing);
      await t.pump(const Duration(seconds: 30));
    });

    testWidgets('offline Join shows the offline page', (t) async {
      w.invite.titles['g2'] = 'Chess club';
      final token = await seed(t, w, 'g2');
      await paste(t, w, token);
      w.invite.failNext = const NetworkFailure(
        'No connection',
        retryable: true,
      );
      await tapKey(t, 'invite-join-button');
      expect(byKey('invite-join-offline-page'), findsOneWidget);
      expect(find.text(l10nEn.inviteJoinedToast), findsNothing);
      await t.pump(const Duration(seconds: 30));
    });
  });
}
