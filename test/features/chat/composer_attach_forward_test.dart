// Update 1 slice 9, from its contract: the paperclip's attach card, the
// composer's greyed buttons and its send/mic swap, the sign-in Apple button,
// the New chat page's greyed permission row, and the Forward picker's chosen
// stack, "Recent" header and "New chat" entry. Written from the contract --
// keys, what a member sees, what the repository is asked to do -- never from
// how the widgets are built.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/auth/presentation/sign_in_screen.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/attachment_sheet.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/new_chat_page.dart';
import 'package:sis/features/chat/presentation/person_avatar.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/sis_ui.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');
const cleo = Member(userId: 'u3', displayName: 'Cleo');
const dana = Member(userId: 'u4', displayName: 'Dana');

Finder byKey(String k) => find.byKey(ValueKey(k));

const greyTiles = ['grey-att_tvoice'];

Message msg(String id, {String body = 'hi', String from = 'u2'}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

class _SignedOut extends SessionController {
  int signIns = 0;
  @override
  Future<SessionState> build() async => const SignedOut();
  @override
  Future<void> signIn() async => signIns++;
}

/// A phone in portrait; [width] logical pixels wide.
void phone(WidgetTester t, {double width = 411, double height = 891}) {
  t.view.physicalSize = Size(width, height);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

Future<ProviderContainer> pumpChat(
  WidgetTester t,
  ChatFake chat, {
  Gallery? gallery,
  double width = 411,
}) async {
  phone(t, width: width);
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        galleryProvider.overrideWithValue(
          gallery ?? GalleryFake(photos: [GalleryPhoto('p1')]),
        ),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  container.read(openConversationProvider.notifier).open('c1');
  await t.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessageScreen(title: 'Bob'),
      ),
    ),
  );
  await t.pumpAndSettle();
  return container;
}

ChatFake world() => ChatFake(self: me.userId)
  ..conversationsResult = const Ok([
    Conversation(id: 'c1', other: bob),
    Conversation(id: 'c2', title: 'Work'),
    Conversation(id: 'c3', title: 'Family'),
    Conversation(id: 'c4', other: dana),
  ])
  ..membersResult = const Ok([bob, cleo, dana])
  ..messagesResult = Ok([msg('m1', body: 'look at this')])
  ..forwardResult = const Ok(null);

String fieldText(WidgetTester t) => t
    .widget<EditableText>(
      find.descendant(
        of: byKey('composer-field'),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

bool fieldFocused(WidgetTester t) => t
    .widget<EditableText>(
      find.descendant(
        of: byKey('composer-field'),
        matching: find.byType(EditableText),
      ),
    )
    .focusNode
    .hasFocus;

void main() {
  group('the attach card', () {
    testWidgets('the paperclip opens the card, not the grid; it holds Photo '
        'Poll, Contact, File, Location and the grey tiles', (t) async {
      await pumpChat(t, world());
      await t.tap(byKey('composer-attach'));
      await t.pumpAndSettle();
      expect(byKey('attach-menu'), findsOneWidget);
      expect(byKey('attach-photo'), findsOneWidget);
      expect(byKey('attach-poll'), findsOneWidget);
      expect(byKey('attach-contact'), findsOneWidget);
      expect(byKey('attach-file'), findsOneWidget);
      expect(byKey('grey-att_tfile'), findsNothing);
      expect(byKey('attach-location'), findsOneWidget);
      expect(byKey('grey-att_tloc'), findsNothing);
      for (final k in greyTiles) {
        expect(byKey(k), findsOneWidget, reason: k);
      }
      expect(byKey('sheet-from-app'), findsNothing, reason: 'grid opened');
    });

    testWidgets('Photo opens the photo grid', (t) async {
      await pumpChat(t, world());
      await t.tap(byKey('composer-attach'));
      await t.pumpAndSettle();
      await t.tap(byKey('attach-photo'));
      await t.pumpAndSettle();
      expect(byKey('attach-menu'), findsNothing);
      expect(byKey('sheet-from-app'), findsOneWidget);
      expect(byKey('sheet-photo-p1'), findsOneWidget);
    });

    for (final how in ['back', 'a tap outside']) {
      testWidgets('backing out of the card ($how) opens nothing', (t) async {
        final chat = world();
        await pumpChat(t, chat);
        await t.tap(byKey('composer-attach'));
        await t.pumpAndSettle();
        if (how == 'back') {
          await t.binding.handlePopRoute();
        } else {
          await t.tapAt(const Offset(20, 120));
        }
        await t.pumpAndSettle();
        expect(byKey('attach-menu'), findsNothing);
        expect(byKey('sheet-from-app'), findsNothing);
        expect(find.byType(MessageScreen), findsOneWidget);
        expect(chat.sent, isEmpty);
      });
    }

    testWidgets('each grey tile is inert: the card stays, nothing opens', (
      t,
    ) async {
      final chat = world();
      await pumpChat(t, chat);
      await t.tap(byKey('composer-attach'));
      await t.pumpAndSettle();
      for (final k in greyTiles) {
        await t.tap(byKey(k));
        await t.pumpAndSettle();
        expect(byKey('attach-menu'), findsOneWidget, reason: '$k closed it');
        expect(byKey('sheet-from-app'), findsNothing, reason: '$k: grid');
      }
      expect(chat.sent, isEmpty);
    });
  });

  group('showAttachMenu', () {
    Future<List<String?>> mount(WidgetTester t) async {
      phone(t);
      final results = <String?>[];
      await t.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: TextButton(
                  key: const ValueKey('open'),
                  onPressed: () async => results.add(
                    await showAttachMenu(
                      context,
                      anchor: const Rect.fromLTWH(8, 840, 40, 40),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await t.tap(byKey('open'));
      await t.pumpAndSettle();
      expect(byKey('attach-menu'), findsOneWidget);
      return results;
    }

    testWidgets('Photo answers photo', (t) async {
      final results = await mount(t);
      await t.tap(byKey('attach-photo'));
      await t.pumpAndSettle();
      expect(results, ['photo']);
    });

    testWidgets('Poll is live and answers poll', (t) async {
      final results = await mount(t);
      expect(byKey('grey-att_tpoll'), findsNothing);
      await t.tap(byKey('attach-poll'));
      await t.pumpAndSettle();
      expect(results, ['poll']);
    });

    testWidgets('File is live and answers file', (t) async {
      final results = await mount(t);
      expect(byKey('grey-att_tfile'), findsNothing);
      await t.tap(byKey('attach-file'));
      await t.pumpAndSettle();
      expect(results, ['file']);
    });

    testWidgets('Contact is live and answers contact', (t) async {
      final results = await mount(t);
      expect(byKey('grey-att_tcon'), findsNothing);
      await t.tap(byKey('attach-contact'));
      await t.pumpAndSettle();
      expect(results, ['contact']);
    });

    testWidgets('Video is live and answers video', (t) async {
      final results = await mount(t);
      expect(byKey('grey-att_tvideo'), findsNothing);
      await t.tap(byKey('attach-video'));
      await t.pumpAndSettle();
      expect(results, ['video']);
    });

    testWidgets('Location is live and answers location', (t) async {
      final results = await mount(t);
      expect(byKey('grey-att_tloc'), findsNothing);
      await t.tap(byKey('attach-location'));
      await t.pumpAndSettle();
      expect(results, ['location']);
    });

    testWidgets('backing out answers null', (t) async {
      final results = await mount(t);
      await t.binding.handlePopRoute();
      await t.pumpAndSettle();
      expect(results, [null]);
    });

    testWidgets('a grey tile answers nothing and leaves the card', (t) async {
      final results = await mount(t);
      await t.tap(byKey('grey-att_tvoice'));
      await t.pumpAndSettle();
      expect(results, isEmpty);
      expect(byKey('attach-menu'), findsOneWidget);
    });
  });

  group('the composer', () {
    testWidgets('empty: sticker, mic and dictation; no send', (t) async {
      await pumpChat(t, world());
      expect(byKey('grey-c_btn'), findsOneWidget);
      expect(byKey('grey-v_rec'), findsOneWidget);
      expect(byKey('grey-v_dict'), findsOneWidget);
      expect(byKey('composer-send'), findsNothing);
    });

    testWidgets('typing swaps the mic for send and hides dictation; '
        'clearing brings them back', (t) async {
      await pumpChat(t, world());
      await t.enterText(byKey('composer-field'), 'hello');
      await t.pump();
      expect(byKey('composer-send'), findsOneWidget);
      expect(byKey('grey-v_rec'), findsNothing);
      expect(byKey('grey-v_dict'), findsNothing);
      expect(byKey('grey-c_btn'), findsOneWidget);

      await t.enterText(byKey('composer-field'), '');
      await t.pump();
      expect(byKey('composer-send'), findsNothing);
      expect(byKey('grey-v_rec'), findsOneWidget);
      expect(byKey('grey-v_dict'), findsOneWidget);
      expect(byKey('grey-c_btn'), findsOneWidget);
    });

    testWidgets('editing: send shows, no mic and no dictation, even with the '
        'field emptied', (t) async {
      final chat = world()
        ..messagesResult = Ok([msg('m9', body: 'mine', from: me.userId)]);
      chat.history['c1'] = [msg('m9', body: 'mine', from: me.userId)];
      await pumpChat(t, chat);
      await t.longPress(byKey('message-m9'));
      await t.pumpAndSettle();
      await t.tap(byKey('menu-edit'));
      await t.pumpAndSettle();
      expect(byKey('edit-bar'), findsOneWidget, reason: 'edit did not open');
      expect(byKey('composer-send'), findsOneWidget);
      expect(byKey('grey-v_dict'), findsNothing);

      await t.enterText(byKey('composer-field'), '');
      await t.pump();
      expect(byKey('composer-send'), findsOneWidget);
      expect(byKey('grey-v_rec'), findsNothing);
      expect(byKey('grey-v_dict'), findsNothing);
      expect(byKey('grey-c_btn'), findsOneWidget);
    });

    testWidgets('type, tap send: it goes out in that frame', (t) async {
      final chat = world();
      await pumpChat(t, chat);
      await t.enterText(byKey('composer-field'), 'right now');
      await t.pump();
      await t.tap(byKey('composer-send'));
      await t.pump();
      expect(chat.sent.map((s) => s.body), ['right now']);
      expect(find.text('right now'), findsOneWidget, reason: 'no bubble yet');
      expect(fieldText(t), isEmpty);
    });

    testWidgets('grey taps do nothing; the field next to them still takes '
        'taps and focus', (t) async {
      final chat = world();
      await pumpChat(t, chat);
      expect(fieldFocused(t), isFalse, reason: 'precondition');
      for (final k in ['grey-c_btn', 'grey-v_rec', 'grey-v_dict']) {
        await t.tap(byKey(k));
        await t.pumpAndSettle();
        expect(find.byType(MessageScreen), findsOneWidget, reason: k);
        expect(byKey('attach-menu'), findsNothing, reason: k);
        expect(fieldText(t), isEmpty, reason: k);
      }
      expect(chat.sent, isEmpty);

      final field = t.getRect(byKey('composer-field'));
      for (final at in [
        field.centerLeft + const Offset(3, 0),
        field.centerRight - const Offset(3, 0),
      ]) {
        FocusManager.instance.primaryFocus?.unfocus();
        await t.pumpAndSettle();
        expect(fieldFocused(t), isFalse);
        await t.tapAt(at);
        await t.pumpAndSettle();
        expect(fieldFocused(t), isTrue, reason: 'a tap at $at missed');
      }
    });
  });

  group('sign-in', () {
    // The default 800-wide surface, as the other sign-in tests use: the
    // test font's square glyphs make the Google label far wider than on a
    // phone.
    Future<_SignedOut> pumpSignIn(WidgetTester t, TargetPlatform p) async {
      final session = _SignedOut();
      await t.pumpWidget(
        ProviderScope(
          overrides: [sessionControllerProvider.overrideWith(() => session)],
          child: MaterialApp(
            theme: sisTheme(Brightness.light).copyWith(platform: p),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const SignInScreen(),
          ),
        ),
      );
      await t.pumpAndSettle();
      return session;
    }

    for (final p in TargetPlatform.values) {
      testWidgets('Apple button on ${p.name}: '
          '${p == TargetPlatform.iOS ? 'shown' : 'absent'}', (t) async {
        await pumpSignIn(t, p);
        expect(
          byKey('grey-s_apple'),
          p == TargetPlatform.iOS ? findsOneWidget : findsNothing,
        );
      });
    }

    for (final p in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('on ${p.name} Google is a FilledButton that signs in', (
        t,
      ) async {
        final session = await pumpSignIn(t, p);
        final google = find.widgetWithText(
          FilledButton,
          'Continue with Google',
        );
        expect(google, findsOneWidget);
        await t.tap(google);
        await t.pump();
        expect(session.signIns, 1);
        if (p == TargetPlatform.iOS) {
          await t.tap(byKey('grey-s_apple'));
          await t.pump();
          expect(session.signIns, 1, reason: 'the grey Apple button signs in');
        }
      });
    }
  });

  testWidgets('New chat: the grey permission row sits below the divider', (
    t,
  ) async {
    phone(t);
    final container = await settled(
      ProviderContainer.test(
        overrides: [
          ...videoOverrides(),
          chatRepositoryProvider.overrideWithValue(world()),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          sessionControllerProvider.overrideWith(_SignedIn.new),
        ],
      ),
    );
    await t.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: NewChatPage(),
        ),
      ),
    );
    await t.pumpAndSettle();
    final perm = t.getRect(byKey('grey-f_perm'));
    final dividers = find.descendant(
      of: byKey('new-chat-page'),
      matching: find.byType(Divider),
    );
    expect(dividers, findsWidgets);
    expect(
      t.getRect(dividers.first).bottom,
      lessThanOrEqualTo(perm.top),
      reason: 'grey-f_perm is not below the divider',
    );
  });

  group('the forward picker', () {
    Future<void> openForward(
      WidgetTester t,
      ChatFake chat, {
      double width = 411,
    }) async {
      await pumpChat(t, chat, width: width);
      await t.longPress(byKey('message-m1'));
      await t.pumpAndSettle();
      await t.tap(byKey('menu-forward'));
      await t.pumpAndSettle();
      expect(byKey('forward-page'), findsOneWidget);
    }

    Future<void> tick(WidgetTester t, String k) async {
      await t.scrollUntilVisible(
        byKey(k),
        100,
        scrollable: find
            .descendant(
              of: byKey('forward-page'),
              matching: find.byType(Scrollable),
            )
            .last,
      );
      await t.tap(byKey(k));
      await t.pumpAndSettle();
    }

    List<String> chosen(WidgetTester t) => [
      for (final e
          in find
              .descendant(
                of: byKey('forward-chosen'),
                matching: find.byType(PersonAvatar),
              )
              .evaluate())
        (e.widget as PersonAvatar).label,
    ];

    testWidgets('its parts: search, strip, Recent, New chat, grey caption; '
        'no chosen stack while nothing is ticked', (t) async {
      await openForward(t, world());
      for (final k in [
        'forward-search',
        'forward-strip',
        'forward-new-chat',
        'grey-caption',
        'forward-send',
      ]) {
        expect(byKey(k), findsOneWidget, reason: k);
      }
      expect(find.text('Recent'), findsOneWidget);
      expect(byKey('forward-chosen'), findsNothing);
    });

    testWidgets('the chosen stack: chats first, then people', (t) async {
      await openForward(t, world());
      await tick(t, 'forward-person-u3');
      await tick(t, 'forward-c2');
      expect(find.text('Send (2)'), findsOneWidget);
      expect(chosen(t), hasLength(2));
      expect(chosen(t).first, contains('Work'));
      expect(chosen(t).last, contains('Cleo'));
    });

    testWidgets('the chosen stack shows at most 3; unticking all removes it', (
      t,
    ) async {
      await openForward(t, world());
      for (final k in ['forward-c2', 'forward-c3', 'forward-c4']) {
        await tick(t, k);
      }
      await tick(t, 'forward-person-u3');
      expect(find.text('Send (4)'), findsOneWidget);
      expect(chosen(t), hasLength(3));
      expect(chosen(t).any((l) => l.contains('Cleo')), isFalse);
      for (final k in [
        'forward-c2',
        'forward-c3',
        'forward-c4',
        'forward-person-u3',
      ]) {
        await tick(t, k);
      }
      expect(byKey('forward-chosen'), findsNothing);
    });

    testWidgets('the grey caption does nothing', (t) async {
      final chat = world();
      await openForward(t, chat);
      await tick(t, 'forward-c2');
      await t.tap(byKey('grey-caption'));
      await t.pumpAndSettle();
      expect(byKey('forward-page'), findsOneWidget);
      expect(find.text('Send (1)'), findsOneWidget);
      expect(chat.forwarded, isEmpty);
    });

    testWidgets('New chat with someone you already chat with ticks that '
        'chat', (t) async {
      final chat = world();
      await openForward(t, chat);
      await t.tap(byKey('forward-new-chat'));
      await t.pumpAndSettle();
      expect(find.byType(NewChatPage), findsOneWidget);
      await t.tap(byKey('member-u4'));
      await t.pumpAndSettle();
      expect(find.byType(NewChatPage), findsNothing);
      expect(byKey('forward-page'), findsOneWidget);
      expect(find.text('Send (1)'), findsOneWidget);
      await t.tap(byKey('forward-send'));
      await t.pumpAndSettle();
      expect(chat.started, isEmpty, reason: 'a second chat was started');
      expect(chat.forwarded.single.conversationIds, ['c4']);
      await drainNotice(t);
    });

    testWidgets('New chat with someone you have no chat with ticks the '
        'person', (t) async {
      final chat = world();
      await openForward(t, chat);
      await t.tap(byKey('forward-new-chat'));
      await t.pumpAndSettle();
      await t.tap(byKey('member-u3'));
      await t.pumpAndSettle();
      expect(byKey('forward-page'), findsOneWidget);
      expect(find.text('Send (1)'), findsOneWidget);
      expect(chosen(t).single, contains('Cleo'));
      await t.tap(byKey('forward-send'));
      await t.pumpAndSettle();
      expect(chat.started, ['u3']);
      expect(chat.forwarded.single.conversationIds, ['c-new']);
      await drainNotice(t);
    });

    testWidgets('New chat with the source chat\'s person ticks nothing; '
        'Send stays off', (t) async {
      final chat = world();
      await openForward(t, chat);
      await t.tap(byKey('forward-new-chat'));
      await t.pumpAndSettle();
      await t.tap(byKey('member-u2'));
      await t.pumpAndSettle();
      expect(byKey('forward-page'), findsOneWidget);
      expect(byKey('forward-chosen'), findsNothing, reason: 'c1 was ticked');
      expect(find.textContaining('Send ('), findsNothing);
      await t.tap(byKey('forward-send'), warnIfMissed: false);
      await t.pumpAndSettle();
      expect(byKey('forward-page'), findsOneWidget);
      expect(chat.forwarded, isEmpty, reason: 'forwarded into its own chat');
      expect(chat.started, isEmpty);
    });

    testWidgets('backing out of New chat ticks nothing', (t) async {
      final chat = world();
      await openForward(t, chat);
      await t.tap(byKey('forward-new-chat'));
      await t.pumpAndSettle();
      await t.pageBack();
      await t.pumpAndSettle();
      expect(byKey('forward-page'), findsOneWidget);
      expect(byKey('forward-chosen'), findsNothing);
    });

    testWidgets('360 wide: the bar with every target ticked fits', (t) async {
      await openForward(t, world(), width: 360);
      for (final k in [
        'forward-c2',
        'forward-c3',
        'forward-c4',
        'forward-person-u3',
      ]) {
        await tick(t, k);
      }
      expect(byKey('forward-chosen'), findsOneWidget);
      expect(t.takeException(), isNull);
      final send = t.getRect(byKey('forward-send'));
      expect(send.right, lessThanOrEqualTo(360));
      expect(send.left, greaterThanOrEqualTo(0));
    });
  });

  group('360 wide, no overflow', () {
    testWidgets('the composer, empty and typed', (t) async {
      await pumpChat(t, world(), width: 360);
      expect(t.takeException(), isNull);
      await t.enterText(
        byKey('composer-field'),
        'a long line of text that runs well past the width of the field',
      );
      await t.pump();
      expect(t.takeException(), isNull);
      expect(t.getRect(byKey('composer-send')).right, lessThanOrEqualTo(360));
    });

    testWidgets('the attach card', (t) async {
      await pumpChat(t, world(), width: 360);
      await t.tap(byKey('composer-attach'));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      final card = t.getRect(byKey('attach-menu'));
      expect(card.left, greaterThanOrEqualTo(0));
      expect(card.right, lessThanOrEqualTo(360));
    });
  });
}
