// repro, written from the contract; the stored chat list carries each group sender's name and colour slot.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_colors.dart';
import 'package:sis/features/chat/domain/group_member.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/last_session_fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const hugh = Member(userId: 'u2', displayName: 'Hugh');
const iona = Member(userId: 'u3', displayName: 'Iona');

final _t0 = DateTime.utc(2026, 10, 1, 9);

Message msg(String id, String from, {String conv = 'g1', int minute = 0}) =>
    Message(
      id: id,
      conversationId: conv,
      senderId: from,
      body: 'text $id',
      createdAt: _t0.add(Duration(minutes: minute)),
    );

class _In extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<ProviderContainer> _container(
  ChatFake chat, {
  List<Override> extra = const [],
}) async {
  final c = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_In.new),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        pushRegistryProvider.overrideWithValue(PushRegistryFake()),
        ...extra,
      ],
    ),
  );
  addTearDown(c.dispose);
  return c;
}

Future<void> steps(WidgetTester t, [int n = 15]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<RichText> firstLabel(WidgetTester t, String messageId) async {
  for (var i = 0; i < 40; i++) {
    await t.pump(const Duration(milliseconds: 16));
    final f = find.descendant(
      of: find.byKey(ValueKey('sender-$messageId')),
      matching: find.byType(RichText),
      matchRoot: true,
    );
    if (f.evaluate().isNotEmpty) {
      return t.widget<RichText>(f);
    }
  }
  fail('no sender label painted for $messageId');
}

void main() {
  testWidgets('warm: the list is loaded, the roster is still on its way: '
      'the first sender label is the real name', (WidgetTester t) async {
    final chat = ChatFake(self: 'u1', latency: const Duration(milliseconds: 2));
    chat.conversationsResult = const Ok([
      Conversation(
        id: 'g1',
        title: 'Club',
        senders: {'u2': GroupVoice('Hugh', 3), 'u3': GroupVoice('Iona', 7)},
      ),
    ]);
    chat.groupRosters['g1'] = [
      GroupMember(member: me, isAdmin: true, colorSlot: 0),
      GroupMember(member: hugh, isAdmin: false, colorSlot: 3),
      GroupMember(member: iona, isAdmin: false, colorSlot: 7),
    ];
    chat.history['g1'] = [
      msg('h1', 'u2', minute: 1),
      msg('i1', 'u3', minute: 2),
    ];

    final c = await _container(chat);
    c.listen(conversationListProvider, (_, _) {});
    await steps(
      t,
      5,
    ); // the list is loaded (fake clock: the fake answers after 2 ms)
    expect(
      c.read(conversationListProvider).hasValue,
      isTrue,
      reason: 'precondition: the list is loaded before the group opens',
    );

    chat.holdPeople(); // keep roster in flight

    c.read(openConversationProvider.notifier).open('g1');
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MessageScreen(group: true, title: 'Club'),
        ),
      ),
    );

    final first = await firstLabel(t, 'h1');
    expect(
      first.text.toPlainText(),
      'Hugh',
      reason: 'first paint must show the stored name, not "Member"',
    );
    expect(first.text.style!.color, Color(groupColorArgb(3, dark: false)));

    chat.releasePeople();
    await steps(t);
    final firstAfter = t.widget<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey('sender-h1')),
        matching: find.byType(RichText),
        matchRoot: true,
      ),
    );
    expect(firstAfter.text.toPlainText(), 'Hugh');
    final second = t.widget<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey('sender-i1')),
        matching: find.byType(RichText),
        matchRoot: true,
      ),
    );
    expect(second.text.toPlainText(), 'Iona');
  });

  testWidgets('cold: app start from the stored list, network list and roster still on their way: '
      'the first sender label is the real name', (WidgetTester t) async {
    final chat = ChatFake(self: 'u1', latency: const Duration(milliseconds: 2));
    chat.conversationsResult = const Ok([
      Conversation(
        id: 'g1',
        title: 'Club',
        senders: {'u2': GroupVoice('Hugh', 3), 'u3': GroupVoice('Iona', 7)},
      ),
    ]);
    chat.groupRosters['g1'] = [
      GroupMember(member: me, isAdmin: true, colorSlot: 0),
      GroupMember(member: hugh, isAdmin: false, colorSlot: 3),
      GroupMember(member: iona, isAdmin: false, colorSlot: 7),
    ];
    chat.history['g1'] = [
      msg('h1', 'u2', minute: 1),
      msg('i1', 'u3', minute: 2),
    ];

    chat.holdList(); // the network list is still on its way
    chat.holdPeople(); // and so is the roster

    final snapshot = MemorySnapshotStore(
      owner: 'u1',
      list: const [
        Conversation(
          id: 'g1',
          title: 'Club',
          senders: {'u2': GroupVoice('Hugh', 3), 'u3': GroupVoice('Iona', 7)},
        ),
      ],
    );

    final c = await _container(
      chat,
      extra: [chatListSnapshotStoreProvider.overrideWithValue(snapshot)],
    );
    c.listen(conversationListProvider, (_, _) {});
    await steps(t, 5); // read stored list

    c.read(openConversationProvider.notifier).open('g1');
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MessageScreen(group: true, title: 'Club'),
        ),
      ),
    );

    final first = await firstLabel(t, 'h1');
    expect(
      first.text.toPlainText(),
      'Hugh',
      reason: 'first paint must show the stored name, not "Member"',
    );
    expect(first.text.style!.color, Color(groupColorArgb(3, dark: false)));

    chat.releaseList();
    chat.releasePeople();
    await steps(t);
    final firstAfter = t.widget<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey('sender-h1')),
        matching: find.byType(RichText),
        matchRoot: true,
      ),
    );
    expect(firstAfter.text.toPlainText(), 'Hugh');
    final second = t.widget<RichText>(
      find.descendant(
        of: find.byKey(const ValueKey('sender-i1')),
        matching: find.byType(RichText),
        matchRoot: true,
      ),
    );
    expect(second.text.toPlainText(), 'Iona');
  });
}
