// A reaction card on screen (copied rig of message_notice_host_test): MessageNoticeHost above a real Navigator watched
// by the real RouteStack, the real MessageNoticeController and chat list over
// ChatFake. Written by QA from the contract only.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/route_stack.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/message_notice_controller.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_colors.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/lock_glyph.dart';
import 'package:sis/features/chat/presentation/message_notice_host.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/domain/reaction_push.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

final now = DateTime.now().toUtc();

Conversation chatWith(String id, Member other, {String text = 'hello'}) =>
    Conversation(
      id: id,
      other: other,
      lastMessage: text,
      lastMessageAt: now,
      lastSenderId: other.userId,
    );

Conversation groupChat(String id, {String text = 'hello'}) => Conversation(
  id: id,
  title: 'Team',
  lastMessage: text,
  lastMessageAt: now,
  lastSenderId: bob.userId,
  senders: const {'u2': GroupVoice('Bob', 0)},
);

Message msg(String chat, {String body = 'hello'}) => Message(
  id: '$chat-${body.hashCode}',
  conversationId: chat,
  senderId: 'u2',
  body: body,
  createdAt: now,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final cardFinder = find.byKey(const ValueKey('message-notice'));

class Rig {
  Rig(this.c, this.nav, this.opened);
  final ProviderContainer c;
  final GlobalKey<NavigatorState> nav;
  final List<String> opened;

  MessageNoticeData? get data => c.read(messageNoticeProvider);

  /// A message for [conv] arrives while chat cA is open.
  void raise(Conversation conv, {String? body}) => c
      .read(messageNoticeProvider.notifier)
      .consider(conv, msg(conv.id, body: body ?? conv.lastMessage!));
}

Future<Rig> mount(
  WidgetTester t, {
  List<Conversation>? list,
  NotificationSettings settings = const NotificationSettings(),
  Locale locale = const Locale('en'),
}) async {
  final chat = ChatFake()
    ..conversationsResult = Ok(
      list ??
          [
            chatWith('cA', bob, text: 'open one'),
            chatWith('cB', bob),
            groupChat('cG'),
          ],
    );
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      sessionControllerProvider.overrideWith(_SignedIn.new),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      notificationSettingsRepositoryProvider.overrideWithValue(
        NotificationSettingsFake(settings: settings),
      ),
    ],
  );
  addTearDown(c.dispose);
  final nav = GlobalKey<NavigatorState>();
  final opened = <String>[];
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        navigatorKey: nav,
        locale: locale,
        theme: sisTheme(Brightness.light),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        navigatorObservers: [c.read(routeStackProvider)],
        builder: (context, child) =>
            MessageNoticeHost(onOpen: opened.add, child: child!),
        home: const Scaffold(body: Center(child: Text('the open chat'))),
      ),
    ),
  );
  // The list, settings and mutes load (the fakes answer after a hop).
  c.listen(conversationListProvider, (_, _) {});
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
  expect(c.read(conversationListProvider).hasValue, isTrue);
  c.read(openConversationProvider.notifier).open('cA');
  await t.pump();
  return Rig(c, nav, opened);
}

ReactionPush rp(
  String chat, {
  String reactor = 'u2',
  String? e = '👍',
  String? q,
}) => (
  userId: 'u1',
  conversationId: chat,
  messageId: 'm1',
  reactorId: reactor,
  emoji: e,
  quote: q,
  quoteKind: null,
  ciphertext: null,
  olmType: null,
);

Future<void> react(Rig r, ReactionPush p) =>
    r.c.read(messageNoticeProvider.notifier).onReactionPush(p);

void main() {
  testWidgets('1:1 reaction card: name as title, text, no lock', (t) async {
    final r = await mount(t);
    await react(r, rp('cB'));
    await t.pump();
    expect(cardFinder, findsOneWidget);
    expect(
      find.descendant(of: cardFinder, matching: find.text('Bob')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: cardFinder,
        matching: find.text('Reacted 👍 to your message'),
      ),
      findsOneWidget,
    );
    expect(find.byType(LockGlyph), findsNothing);
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('group reaction card: "Name: " prefix', (t) async {
    final r = await mount(t);
    await react(r, rp('cG', q: 'hi'));
    await t.pump();
    expect(
      find.descendant(
        of: cardFinder,
        matching: find.text('Bob: Reacted 👍 to: "hi"'),
      ),
      findsOneWidget,
    );
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('Turkish card', (t) async {
    final r = await mount(t, locale: const Locale('tr'));
    await react(r, rp('cB'));
    await t.pump();
    expect(
      find.descendant(
        of: cardFinder,
        matching: find.text('Mesajınıza 👍 tepkisini verdi'),
      ),
      findsOneWidget,
    );
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('chat not in the local list: no card drawn', (t) async {
    final r = await mount(t);
    await react(r, rp('cZ'));
    await t.pump();
    expect(cardFinder, findsNothing);
    await t.pump(const Duration(seconds: 6));
  });

  testWidgets('chat list open: no card; same chat: no card', (t) async {
    final r = await mount(t);
    r.c.read(openConversationProvider.notifier).close();
    await react(r, rp('cB'));
    await t.pump();
    expect(cardFinder, findsNothing);
    r.c.read(openConversationProvider.notifier).open('cB');
    await react(r, rp('cB'));
    await t.pump();
    expect(cardFinder, findsNothing);
  });
}
