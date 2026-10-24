// The top card on screen: MessageNoticeHost above a real Navigator watched
// by the real RouteStack, the real MessageNoticeController and chat list over
// ChatFake. Written by QA from the contract only.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/chat/domain/group_colors.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/lock_glyph.dart';
import 'package:sis/features/chat/presentation/message_notice_host.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/l10n.dart';
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

Future<void> pumpFor(WidgetTester t, Duration d) async {
  final end = d.inMilliseconds;
  for (var ms = 0; ms < end; ms += 50) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Route<void> viewerRoute() => PageRouteBuilder<void>(
  settings: fullScreenMedia,
  pageBuilder: (_, _, _) => const Scaffold(body: Text('viewer')),
);

Route<void> plainRoute() => PageRouteBuilder<void>(
  pageBuilder: (_, _, _) => const Scaffold(body: Text('plain page')),
);

void main() {
  group('card content', () {
    testWidgets('1:1: title is the person, body the text only', (t) async {
      final r = await mount(t);
      r.raise(chatWith('cB', bob));
      await t.pump();
      expect(cardFinder, findsOneWidget, reason: 'drawn in the same frame');
      expect(
        find.descendant(of: cardFinder, matching: find.text('Bob')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: cardFinder, matching: find.text('hello')),
        findsOneWidget,
      );
      expect(find.byType(LockGlyph), findsNothing);
      await pumpFor(t, const Duration(seconds: 5));
    });

    testWidgets('group: body is "Sender: text"', (t) async {
      final r = await mount(t);
      r.raise(groupChat('cG'));
      await t.pump();
      expect(
        find.descendant(of: cardFinder, matching: find.text('Team')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: cardFinder, matching: find.text('Bob: hello')),
        findsOneWidget,
      );
      await pumpFor(t, const Duration(seconds: 5));
    });

    testWidgets('second message shows "+2"', (t) async {
      final r = await mount(t);
      r.raise(chatWith('cB', bob));
      await t.pump();
      r.raise(chatWith('cB', bob, text: 'again'));
      await t.pump();
      expect(
        find.descendant(of: cardFinder, matching: find.text('+2')),
        findsOneWidget,
      );
      await pumpFor(t, const Duration(seconds: 5));
    });

    testWidgets('locked placeholder: lock glyph + "New message", never the '
        'placeholder', (t) async {
      final r = await mount(
        t,
        list: [chatWith('cB', bob, text: lockedBodyPlaceholder)],
      );
      r.raise(chatWith('cB', bob, text: lockedBodyPlaceholder));
      await t.pump();
      expect(r.data!.locked, isTrue);
      expect(find.byType(LockGlyph), findsOneWidget);
      expect(find.textContaining('New message'), findsOneWidget);
      expect(find.textContaining('Encrypted message'), findsNothing);
      await pumpFor(t, const Duration(seconds: 5));
    });

    testWidgets('preview setting none: "New message", no text, no lock', (
      t,
    ) async {
      final r = await mount(
        t,
        settings: const NotificationSettings(preview: NotificationPreview.none),
      );
      r.raise(chatWith('cB', bob, text: 'secret plan'));
      await t.pump();
      expect(cardFinder, findsOneWidget);
      expect(find.textContaining('secret plan'), findsNothing);
      expect(find.textContaining('New message'), findsOneWidget);
      expect(find.byType(LockGlyph), findsNothing);
      await pumpFor(t, const Duration(seconds: 5));
    });

    testWidgets('Turkish: "Yeni mesaj"', (t) async {
      final r = await mount(
        t,
        locale: const Locale('tr'),
        settings: const NotificationSettings(
          preview: NotificationPreview.sender,
        ),
      );
      r.raise(chatWith('cB', bob));
      await t.pump();
      expect(find.textContaining('Yeni mesaj'), findsOneWidget);
      expect(l10nEn.noticeNewMessage, 'New message');
      expect(l10nTr.noticeNewMessage, 'Yeni mesaj');
      await pumpFor(t, const Duration(seconds: 5));
    });

    testWidgets('a chat missing from the list renders nothing', (t) async {
      final r = await mount(t);
      r.raise(chatWith('cZ', bob));
      await t.pump();
      expect(find.text('hello'), findsNothing);
      expect(find.text('Bob'), findsNothing);
      await pumpFor(t, const Duration(seconds: 5));
    });

    testWidgets('screen readers hear "<title>: <body>" as a live region', (
      t,
    ) async {
      final handle = t.ensureSemantics();
      final r = await mount(t);
      r.raise(chatWith('cB', bob));
      await t.pump();
      await pumpFor(t, const Duration(milliseconds: 500));
      // The live region the card announces, wherever it sits in the tree.
      final live = <SemanticsNode>[];
      bool visit(SemanticsNode n) {
        if (n.getSemanticsData().flagsCollection.isLiveRegion) live.add(n);
        n.visitChildren(visit);
        return true;
      }

      var root = t.getSemantics(cardFinder);
      while (root.parent != null) {
        root = root.parent!;
      }
      visit(root);
      expect(live, hasLength(1));
      // Exactly the contract label: the title and body heard once, not
      // followed by the card's own texts (avatar initial, name, body) again.
      expect(live.single.label, 'Bob: hello');
      await pumpFor(t, const Duration(seconds: 5));
      handle.dispose();
    });
  });

  group('host behaviour', () {
    testWidgets('fades and slides in', (t) async {
      final r = await mount(t);
      r.raise(chatWith('cB', bob));
      await t.pump();
      final fade = t.widget<FadeTransition>(
        find
            .ancestor(of: cardFinder, matching: find.byType(FadeTransition))
            .first,
      );
      expect(fade.opacity.value, lessThan(1), reason: 'starts faded');
      final startTop = t.getRect(cardFinder).top;
      await pumpFor(t, const Duration(milliseconds: 800));
      expect(fade.opacity.value, 1);
      expect(
        t.getRect(cardFinder).top,
        greaterThan(startTop),
        reason: 'slides down from the top',
      );
      await pumpFor(t, const Duration(seconds: 5));
    });

    testWidgets('closes by itself after 4 s, not before', (t) async {
      final r = await mount(t);
      r.raise(chatWith('cB', bob));
      await t.pump();
      await pumpFor(t, const Duration(milliseconds: 3700));
      expect(cardFinder, findsOneWidget, reason: 'still inside its 4 s');
      expect(r.data, isNotNull);
      await pumpFor(t, const Duration(milliseconds: 1300));
      expect(r.data, isNull);
      expect(cardFinder, findsNothing);
    });

    testWidgets('swipe up closes it; sideways does nothing', (t) async {
      final r = await mount(t);
      r.raise(chatWith('cB', bob));
      await t.pump();
      await pumpFor(t, const Duration(milliseconds: 400));
      await t.drag(cardFinder, const Offset(160, 0));
      await pumpFor(t, const Duration(milliseconds: 500));
      expect(cardFinder, findsOneWidget, reason: 'sideways closed it');
      expect(r.data, isNotNull);
      expect(r.opened, isEmpty);

      await t.fling(cardFinder, const Offset(0, -120), 1000);
      await pumpFor(t, const Duration(milliseconds: 600));
      expect(r.data, isNull);
      expect(cardFinder, findsNothing);
      expect(r.opened, isEmpty, reason: 'a swipe is not a tap');
    });

    testWidgets('tap opens its chat once and closes the card', (t) async {
      final r = await mount(t);
      r.raise(chatWith('cB', bob));
      await t.pump();
      await pumpFor(t, const Duration(milliseconds: 400));
      await t.tap(cardFinder);
      await pumpFor(t, const Duration(milliseconds: 600));
      expect(r.opened, ['cB']);
      expect(r.data, isNull);
      expect(cardFinder, findsNothing);
    });
  });

  group('route rule', () {
    testWidgets('mediaOnTop follows the full-screen viewer', (t) async {
      final r = await mount(t);
      final stack = r.c.read(routeStackProvider);
      expect(stack.mediaOnTop.value, isFalse);

      r.nav.currentState!.push(viewerRoute());
      await t.pump();
      expect(stack.mediaOnTop.value, isTrue, reason: 'viewer pushed');

      r.nav.currentState!.push(plainRoute());
      await t.pump();
      expect(stack.mediaOnTop.value, isFalse, reason: 'a page above it');

      r.nav.currentState!.pop();
      await pumpFor(t, const Duration(milliseconds: 500));
      expect(stack.mediaOnTop.value, isTrue, reason: 'back on the viewer');

      r.nav.currentState!.pop();
      await pumpFor(t, const Duration(milliseconds: 500));
      expect(stack.mediaOnTop.value, isFalse, reason: 'viewer popped');

      r.nav.currentState!.push(plainRoute());
      await pumpFor(t, const Duration(milliseconds: 500));
      r.nav.currentState!.pushReplacement(viewerRoute());
      await pumpFor(t, const Duration(milliseconds: 500));
      expect(stack.mediaOnTop.value, isTrue, reason: 'replaced by viewer');

      r.nav.currentState!.removeRoute(
        ModalRoute.of(t.element(find.text('viewer')))!,
      );
      await pumpFor(t, const Duration(milliseconds: 500));
      expect(stack.mediaOnTop.value, isFalse, reason: 'viewer removed');
    });

    testWidgets('due under the viewer: not drawn; viewer closes inside 4 s: '
        'drawn', (t) async {
      final r = await mount(t);
      r.nav.currentState!.push(viewerRoute());
      await pumpFor(t, const Duration(milliseconds: 500));
      r.raise(chatWith('cB', bob));
      await t.pump();
      await pumpFor(t, const Duration(milliseconds: 1000));
      expect(cardFinder, findsNothing, reason: 'drawn over the viewer');

      r.nav.currentState!.pop();
      await t.pump();
      await pumpFor(t, const Duration(milliseconds: 500));
      expect(cardFinder, findsOneWidget, reason: 'viewer closed at ~1.5 s');
      await pumpFor(t, const Duration(seconds: 5));
    });

    testWidgets('viewer closes after the 4 s: no card', (t) async {
      final r = await mount(t);
      r.nav.currentState!.push(viewerRoute());
      await pumpFor(t, const Duration(milliseconds: 500));
      r.raise(chatWith('cB', bob));
      await t.pump();
      await pumpFor(t, const Duration(milliseconds: 4500));
      r.nav.currentState!.pop();
      await pumpFor(t, const Duration(milliseconds: 800));
      expect(cardFinder, findsNothing);
    });

    testWidgets('a non-viewer page on top: card drawn', (t) async {
      final r = await mount(t);
      r.nav.currentState!.push(plainRoute());
      await pumpFor(t, const Duration(milliseconds: 500));
      r.raise(chatWith('cB', bob));
      await t.pump();
      expect(cardFinder, findsOneWidget);
      await pumpFor(t, const Duration(seconds: 5));
    });
  });
}
