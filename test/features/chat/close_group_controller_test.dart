// GroupController.closeGroup and the close-event provider, against the shared
// fakes. Written from the contract: Ok drops the queue and draft, re-reads the
// roster, events and list; Err comes back unchanged and touches nothing.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/application/group_controller.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/domain/group_member.dart';

import '../../support/fakes.dart';
import '../../support/group_settings_fakes.dart';
import '../../support/held_send_chat.dart';
import '../../support/video_fakes.dart';
import 'group_controller_test.dart'
    show bob, groups, hop, inList, queueOffline, queued, settle;

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<ProviderContainer> startReal(
  HeldSendChat chat,
  GroupSettingsFake settings,
) async {
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      groupSettingsRepositoryProvider.overrideWithValue(settings),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  );
  await settled(c);
  c.listen(sendQueueProvider, (_, _) {});
  c.listen(conversationListProvider, (_, _) {});
  await c.read(conversationListProvider.future);
  return c;
}

void main() {
  final closedEvent = GroupEvent(
    id: 'e1',
    conversationId: 'g1',
    kind: GroupEventKind.closed,
    subjectId: 'u1',
    actorId: 'u1',
    createdAt: DateTime.utc(2026, 11, 1),
  );

  group('GroupController.closeGroup', () {
    testWidgets('Ok: queue and draft of that chat dropped, the other chat '
        'kept, the list re-read', (t) async {
      final chat = groups();
      final settings = GroupSettingsFake(latency: Duration.zero);
      final c = ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(chat),
          groupSettingsRepositoryProvider.overrideWithValue(settings),
          sessionControllerProvider.overrideWith(_SignedIn.new),
        ],
      );
      c.listen(sessionControllerProvider, (_, _) {});
      c.listen(sendQueueProvider, (_, _) {});
      c.listen(conversationListProvider, (_, _) {});
      await hop(t);
      await t.pump(const Duration(milliseconds: 1));
      await queueOffline(t, c, chat, 'g1', ['a', 'b']);
      final drafts = c.read(draftsProvider.notifier)
        ..setText('g1', 'half')
        ..setText('g2', 'keep me');
      // What the server lists once the group is closed.
      chat.conversationsResult = const Ok([
        Conversation(id: 'g1', title: 'Trip', hasLeft: true),
        Conversation(id: 'g2', title: 'Club'),
      ]);

      final f = c.read(groupControllerProvider).closeGroup('g1');
      await hop(t);
      await t.pump(const Duration(milliseconds: 50));
      await hop(t);
      final r = await f;
      await hop(t);

      expect(r, isA<Ok<void>>());
      expect(settings.calls, contains('close:g1'));
      expect(queued(c, 'g1'), isEmpty, reason: 'queue survived the close');
      expect(drafts.draftFor('g1').text, isEmpty);
      expect(drafts.draftFor('g2').text, 'keep me');
      expect(inList(c, 'g1')?.hasLeft, isTrue, reason: 'list not re-read');
    });

    testWidgets('Err comes back unchanged and drops nothing', (t) async {
      final chat = groups();
      final settings = GroupSettingsFake(latency: Duration.zero)
        ..closeResult = const Err(DeniedFailure());
      final c = ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(chat),
          groupSettingsRepositoryProvider.overrideWithValue(settings),
          sessionControllerProvider.overrideWith(_SignedIn.new),
        ],
      );
      c.listen(sessionControllerProvider, (_, _) {});
      c.listen(sendQueueProvider, (_, _) {});
      c.listen(conversationListProvider, (_, _) {});
      await hop(t);
      await t.pump(const Duration(milliseconds: 1));
      await queueOffline(t, c, chat, 'g1', ['a']);
      c.read(draftsProvider.notifier).setText('g1', 'still mine');
      chat.conversationsResult = const Ok([
        Conversation(id: 'g1', title: 'Trip', hasLeft: true),
        Conversation(id: 'g2', title: 'Club'),
      ]);

      final f = c.read(groupControllerProvider).closeGroup('g1');
      await hop(t);
      await t.pump(const Duration(milliseconds: 50));
      await hop(t);
      final r = await f;
      await hop(t);

      expect(r, isA<Err<void>>());
      expect((r as Err<void>).failure, isA<DeniedFailure>());
      expect(queued(c, 'g1'), hasLength(1));
      expect(c.read(draftsProvider.notifier).draftFor('g1').text, 'still mine');
      expect(inList(c, 'g1')?.hasLeft, isFalse, reason: 'reloaded on refusal');
      c.dispose();
    });

    test('Ok re-reads the roster and the close events on screen', () async {
      final chat = groups();
      final settings = GroupSettingsFake(latency: Duration.zero);
      final c = await startReal(chat, settings);
      c.listen(groupRosterProvider('g1'), (_, _) {});
      c.listen(groupCloseEventsProvider('g1'), (_, _) {});
      await settle();
      expect(c.read(groupCloseEventsProvider('g1')).value, isEmpty);
      expect(
        c.read(groupRosterProvider('g1')).value!.any((m) => m.hasLeft),
        isFalse,
      );

      // What the server holds after the close.
      chat.groupRosters['g1'] = [
        const GroupMember(
          member: me,
          isAdmin: true,
          leftReason: LeftReason.removed,
        ),
        const GroupMember(
          member: bob,
          isAdmin: false,
          leftReason: LeftReason.removed,
        ),
      ];
      settings.closures['g1'] = [closedEvent];
      final r = await c.read(groupControllerProvider).closeGroup('g1');
      await settle();

      expect(r, isA<Ok<void>>());
      expect(
        c
            .read(groupRosterProvider('g1'))
            .value!
            .every((m) => m.leftReason == LeftReason.removed),
        isTrue,
        reason: 'roster not re-read',
      );
      expect(c.read(groupCloseEventsProvider('g1')).value, [closedEvent]);
    });
  });
}
