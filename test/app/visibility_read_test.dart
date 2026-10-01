// SessionGate's lifecycle wiring (0.30.5), mounted as main.dart mounts it:
// the real SisApp, real controllers, the chat opened by tapping its row.
// onHide -> appVisibleProvider false; onShow -> true, then the resume
// catch-up. A message arriving while hidden is not marked read; on return the
// open chat is marked read exactly once and its read marks are re-read.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../support/fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

final _t0 = DateTime.utc(2026, 9, 29, 12);

Message msg(String id, int minute, {String from = 'u2'}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: 'body $id',
  createdAt: _t0.add(Duration(minutes: minute)),
);

Future<void> lifecycle(WidgetTester t, List<AppLifecycleState> s) async {
  for (final state in s) {
    t.binding.handleAppLifecycleStateChanged(state);
    await t.pump();
  }
  await t.pumpAndSettle();
}

const away = [
  AppLifecycleState.inactive,
  AppLifecycleState.hidden,
  AppLifecycleState.paused,
];
const back = [
  AppLifecycleState.hidden,
  AppLifecycleState.inactive,
  AppLifecycleState.resumed,
];

void main() {
  late ChatFake chat;

  Future<ProviderContainer> launchIntoChat(WidgetTester t) async {
    chat = ChatFake(self: 'u1')
      ..history['c1'] = [msg('m1', 1)]
      ..conversationsResult = Ok([
        Conversation(
          id: 'c1',
          title: 'Bob',
          lastMessage: 'body m1',
          lastMessageAt: _t0.add(const Duration(minutes: 1)),
          lastSenderId: 'u2',
        ),
      ])
      ..readMarksData['c1'] = [
        ReadMark(userId: 'u2', shares: true, readAt: _t0),
      ];
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          runtimeConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(FakeAuth(session: true)),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          chatRepositoryProvider.overrideWithValue(chat),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          profileRepositoryProvider.overrideWithValue(ProfileFake()),
          pushSourceProvider.overrideWithValue(PushSourceFake()),
          pushRegistryProvider.overrideWithValue(PushRegistryFake()),
        ],
        child: const SisApp(),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Bob'));
    await t.pumpAndSettle();
    expect(find.text('body m1'), findsWidgets, reason: 'chat not open');
    return ProviderScope.containerOf(t.element(find.byType(SisApp)));
  }

  testWidgets('going to the background hides the app; coming back shows '
      'it', (t) async {
    final c = await launchIntoChat(t);
    expect(c.read(appVisibleProvider), isTrue);

    await lifecycle(t, away);
    expect(c.read(appVisibleProvider), isFalse, reason: 'onHide');

    await lifecycle(t, back);
    expect(c.read(appVisibleProvider), isTrue, reason: 'onShow');
  });

  testWidgets('a message arriving while hidden is not marked read; on return '
      'the chat is marked read once and its read marks are re-read', (t) async {
    await launchIntoChat(t);
    await lifecycle(t, away);
    final marked = chat.markedRead.length;

    chat.deliver(msg('m2', 2));
    await t.pumpAndSettle();
    expect(
      chat.markedRead.sublist(marked),
      isEmpty,
      reason: 'marked read while nobody saw it',
    );

    final reads = chat.readMarksCalls.length;
    await lifecycle(t, back);

    expect(chat.markedRead.sublist(marked), ['c1']);
    expect(chat.readMarksCalls.length, reads + 1, reason: 'marks re-read');
    expect(find.text('body m2'), findsWidgets);
  });
}
