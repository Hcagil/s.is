// Unsent text stays in each chat, and an offline send waits and goes by
// itself (2026-09-28), as the member sees it: the whole app as main.dart
// mounts it (SisApp, its session gate and its lifecycle hooks), chats
// opened from the list, fakes only at the repository boundaries. Written
// from the contract, never from how the composer or the queue is built.
//
// The server answers only when the test says so, and a failure is either
// "no connection" (retryable, as readableFailure() classifies it) or a
// refusal.
//
// Since 2026-09-28 (v0.21.4, owner) the chat list no longer says "Draft: …":
// a chat with unsent text shows its last message, and the draft lives only in
// that chat's write box. [listShowsNoDraft] holds the list to that.
//
// Run under TZ=JST-9 like every unit test.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/fakes.dart';
import '../../support/held_send_chat.dart';
import '../../support/sis_ui.dart';

const bob = Member(userId: 'u2', displayName: 'Bob Stone');
const cem = Member(userId: 'u3', displayName: 'Cem Ay');
const offline = NetworkFailure('No connection', retryable: true);
const refused = DeniedFailure();

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);

Message msg(String id, String conv, String body, {String from = 'u2'}) =>
    Message(
      id: id,
      conversationId: conv,
      senderId: from,
      body: body,
      createdAt: DateTime.now().subtract(const Duration(minutes: 5)),
    );

class World {
  World() {
    chat
      ..conversationsResult = const Ok([
        Conversation(id: 'c1', other: bob, lastMessage: 'where are you'),
        Conversation(id: 'c2', other: cem, lastMessage: 'hey'),
      ])
      ..history['c1'] = [
        msg('m1', 'c1', 'where are you'),
        msg('mine', 'c1', 'see you at 5', from: me.userId),
      ]
      ..history['c2'] = [msg('n1', 'c2', 'hey')];
  }

  final chat = HeldSendChat();

  Widget app() => ProviderScope(
    overrides: [
      runtimeConfigProvider.overrideWithValue(config),
      authRepositoryProvider.overrideWithValue(
        FakeAuth(session: true, member: me),
      ),
      updateRepositoryProvider.overrideWithValue(FakeUpdate()),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      profileRepositoryProvider.overrideWithValue(
        ProfileFake(
          profile: const OwnProfile(
            userId: 'u1',
            displayName: 'Maya',
            tag: 'maya',
            onboardingDone: true,
          ),
        ),
      ),
      linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
      pushSourceProvider.overrideWithValue(PushSourceFake()),
      pushRegistryProvider.overrideWithValue(PushRegistryFake()),
      attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
    ],
    child: const SisApp(),
  );
}

Finder byKey(String key) => find.byKey(ValueKey(key));
final field = byKey('composer-field');
final send = byKey('composer-send');
final replyBar = byKey('reply-bar');
final editBar = byKey('edit-bar');
final clock = find.byIcon(Icons.schedule_rounded);
Finder bubble(String id) => byKey('message-$id');
Finder draftPreview(String conv) => byKey('draft-preview-$conv');

/// The list, back from a chat with unsent [draft]: nowhere a "Draft" label,
/// the draft's text nowhere in the tile, and the subtitle is the chat's
/// last message ([last]) as before drafts existed.
void listShowsNoDraft(
  WidgetTester t,
  String conv, {
  required String draft,
  required String last,
}) {
  expect(find.byType(MessageScreen), findsNothing, reason: 'not on the list');
  expect(byKey('conversation-$conv'), findsOneWidget);
  expect(draftPreview(conv), findsNothing);
  expect(
    find.textContaining('Draft', findRichText: true),
    findsNothing,
    reason: 'the list shows no draft (owner, v0.21.4)',
  );
  final tile = textIn(t, byKey('conversation-$conv'));
  expect(tile, contains(last), reason: 'the last message is the subtitle');
  expect(tile, isNot(contains(draft.split('\n').first)));
}

/// Frames without moving the clock far: 240 ms in all.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 20));
  }
}

Future<void> start(WidgetTester t, World w) async {
  await t.pumpWidget(w.app());
  await settle(t);
  expect(byKey('conversation-c1'), findsOneWidget, reason: 'no list');
}

Future<void> openChat(WidgetTester t, String id) async {
  await t.tap(byKey('conversation-$id'));
  await settle(t);
  expect(find.byType(MessageScreen), findsOneWidget);
}

Future<void> back(WidgetTester t) async {
  await t.pageBack();
  for (
    var i = 0;
    i < 40 && find.byType(MessageScreen).evaluate().isNotEmpty;
    i++
  ) {
    await t.pump(const Duration(milliseconds: 50));
  }
  expect(find.byType(MessageScreen), findsNothing);
  await settle(t);
}

EditableText editable(WidgetTester t) => t.widget<EditableText>(
  find.descendant(of: field, matching: find.byType(EditableText)),
);
String composerText(WidgetTester t) => editable(t).controller.text;

Future<void> type(WidgetTester t, String text) async {
  await t.enterText(field, text);
  await t.pump();
}

Future<void> sendText(WidgetTester t, String text) async {
  await type(t, text);
  await t.tap(send);
  await t.pump();
}

Future<void> swipeAction(WidgetTester t, String id, String action) async {
  await t.drag(bubble(id), swipeOpen);
  await settle(t);
  await t.tap(byKey('action-$action'));
  await settle(t);
}

String textIn(WidgetTester t, Finder of) => [
  for (final e
      in find
          .descendant(of: of, matching: find.byType(RichText), matchRoot: true)
          .evaluate())
    (e.widget as RichText).text.toPlainText(),
].join(' ');

/// Whether every piece of text under [of] is drawn in italic.
bool allItalic(WidgetTester t, Finder of) {
  var sawText = false;
  var all = true;
  void walk(InlineSpan span, FontStyle? inherited) {
    final style = span.style?.fontStyle ?? inherited;
    if (span is TextSpan) {
      if ((span.text ?? '').trim().isNotEmpty) {
        sawText = true;
        if (style != FontStyle.italic) all = false;
      }
      for (final c in span.children ?? const <InlineSpan>[]) {
        walk(c, style);
      }
    }
  }

  for (final e
      in find
          .descendant(of: of, matching: find.byType(RichText), matchRoot: true)
          .evaluate()) {
    walk((e.widget as RichText).text, null);
  }
  return sawText && all;
}

/// Moves the app to the background and back, as the OS does.
Future<void> background(WidgetTester t) async {
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
  await t.pump();
}

Future<void> foreground(WidgetTester t) async {
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await t.pump();
}

void main() {
  group('a draft', () {
    testWidgets('survives going back: the list shows the last message, not '
        'the draft, and reopening puts the text back with the cursor at '
        'the end', (t) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await type(t, 'running late\nsorry');
      await back(t);

      listShowsNoDraft(t, 'c1', draft: 'running late', last: 'where are you');
      expect(
        allItalic(t, byKey('conversation-c1')),
        isFalse,
        reason: 'no italic draft line in the tile',
      );

      await openChat(t, 'c1');
      expect(composerText(t), 'running late\nsorry');
      expect(
        editable(t).controller.selection,
        const TextSelection.collapsed(offset: 'running late\nsorry'.length),
        reason: 'the cursor is at the end, ready to go on typing',
      );
      expect(w.chat.asked, isEmpty, reason: 'a draft is never sent');
    });

    testWidgets('belongs to its chat: another chat opens empty, and its own '
        'draft is kept apart', (t) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await type(t, 'for bob');
      await back(t);

      await openChat(t, 'c2');
      expect(composerText(t), isEmpty);
      expect(replyBar, findsNothing);
      await type(t, 'for cem');
      await back(t);

      listShowsNoDraft(t, 'c1', draft: 'for bob', last: 'where are you');
      listShowsNoDraft(t, 'c2', draft: 'for cem', last: 'hey');
      await openChat(t, 'c1');
      expect(composerText(t), 'for bob');
      await back(t);
      await openChat(t, 'c2');
      expect(composerText(t), 'for cem');
    });

    testWidgets('keeps the reply target: the reply bar comes back with it', (
      t,
    ) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await swipeAction(t, 'm1', 'reply');
      expect(replyBar, findsOneWidget);
      await type(t, 'on my way');
      await back(t);

      await openChat(t, 'c2');
      expect(replyBar, findsNothing, reason: 'the reply is c1\'s only');
      await back(t);

      await openChat(t, 'c1');
      expect(composerText(t), 'on my way');
      expect(replyBar, findsOneWidget);
      expect(textIn(t, replyBar), contains('where are you'));
    });

    testWidgets('keeps the reply target across going back and reopening', (
      t,
    ) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await swipeAction(t, 'm1', 'reply');
      await type(t, 'on my way');
      await back(t);
      await openChat(t, 'c1');
      expect(composerText(t), 'on my way');
      expect(replyBar, findsOneWidget);
      expect(textIn(t, replyBar), contains('where are you'));
    });

    testWidgets('a reply target alone, with nothing typed, is kept too', (
      t,
    ) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await swipeAction(t, 'm1', 'reply');
      await back(t);
      await openChat(t, 'c1');
      expect(replyBar, findsOneWidget);
    });

    testWidgets('emptying the box leaves no draft behind', (t) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await type(t, 'never mind');
      await type(t, '');
      await back(t);

      expect(draftPreview('c1'), findsNothing);
      expect(
        textIn(t, byKey('conversation-c1')),
        contains('where are you'),
        reason: 'the last message is the subtitle again',
      );
      await openChat(t, 'c1');
      expect(composerText(t), isEmpty);
    });

    testWidgets('survives the app going to the background and back', (t) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await type(t, 'half a thought');
      await background(t);
      await t.pump(const Duration(minutes: 1));
      await foreground(t);
      await settle(t);

      expect(composerText(t), 'half a thought');
      await back(t);
      listShowsNoDraft(t, 'c1', draft: 'half a thought', last: 'where are you');
      await openChat(t, 'c1');
      expect(composerText(t), 'half a thought', reason: 'the box still has it');
    });

    testWidgets('is gone once sent: no preview, and the chat reopens empty', (
      t,
    ) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await sendText(t, 'hello');
      await back(t);
      expect(draftPreview('c1'), findsNothing);
      w.chat.ok(0);
      await settle(t);
      await openChat(t, 'c1');
      expect(composerText(t), isEmpty);
    });
  });

  group('edit mode', () {
    testWidgets('is never a draft: leaving cancels the edit and the text '
        'from before the edit comes back', (t) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await type(t, 'my draft');
      await swipeAction(t, 'mine', 'edit');
      expect(editBar, findsOneWidget);
      expect(composerText(t), 'see you at 5');
      await type(t, 'see you at 6');
      await back(t);

      listShowsNoDraft(t, 'c1', draft: 'my draft', last: 'where are you');
      expect(
        find.textContaining('see you at 6', findRichText: true),
        findsNothing,
        reason: 'the edit text is never kept as a draft',
      );
      await openChat(t, 'c1');
      expect(editBar, findsNothing, reason: 'leaving cancelled the edit');
      expect(composerText(t), 'my draft');
      expect(textIn(t, bubble('mine')), contains('see you at 5'));
      expect(w.chat.asked, isEmpty);
    });

    testWidgets('with nothing drafted before, leaves no draft', (t) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await swipeAction(t, 'mine', 'edit');
      expect(editBar, findsOneWidget);
      await back(t);

      expect(draftPreview('c1'), findsNothing);
      await openChat(t, 'c1');
      expect(editBar, findsNothing);
      expect(composerText(t), isEmpty);
    });

    testWidgets('cancelling the edit brings the draft back', (t) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await type(t, 'my draft');
      await swipeAction(t, 'mine', 'edit');
      await t.tap(byKey('edit-cancel'));
      await settle(t);
      expect(editBar, findsNothing);
      expect(composerText(t), 'my draft');
    });
  });

  group('offline', () {
    testWidgets('sends keep their clocks, no notice, the box stays empty; '
        'when the connection is back they are stored in place, same '
        'bubble, no clock', (t) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await sendText(t, 'one');
      await sendText(t, 'two');
      await settle(t);
      final ids = [for (final m in w.chat.asked) m.id];
      expect(ids, hasLength(1));

      w.chat.fail(0, offline);
      await settle(t);
      expect(clock, findsNWidgets(2), reason: 'both still on their way');
      expect(notice, findsNothing, reason: 'no per-message notice');
      expect(composerText(t), isEmpty, reason: 'nothing comes back');
      expect(draftPreview('c1'), findsNothing);

      await t.pump(const Duration(seconds: 1));
      await settle(t);
      expect(w.chat.asked, hasLength(2));
      expect(w.chat.asked[1].id, ids.single, reason: 'the same message');
      w.chat.ok(1);
      await settle(t);
      w.chat.ok(2);
      await settle(t);

      expect(clock, findsNothing);
      expect(bubble(ids.single), findsOneWidget);
      expect(bubble(w.chat.asked[2].id), findsOneWidget);
      expect(textIn(t, bubble(ids.single)), contains('one'));
      expect(textIn(t, bubble(w.chat.asked[2].id)), contains('two'));
      expect(notice, findsNothing);
    });

    testWidgets('leaving and coming back mid-retry still shows the clocks', (
      t,
    ) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await sendText(t, 'one');
      await settle(t);
      w.chat.fail(0, offline);
      await settle(t);
      await back(t);
      await openChat(t, 'c1');

      final id = w.chat.asked.first.id;
      expect(clock, findsOneWidget);
      expect(bubble(id), findsOneWidget);
      for (var i = 0; i < 20 && w.chat.asked.length < 2; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(w.chat.asked.last.id, id, reason: 'retried as the same message');
      w.chat.ok(w.chat.asked.length - 1);
      await settle(t);
      expect(clock, findsNothing);
      expect(bubble(w.chat.asked.first.id), findsOneWidget);
    });

    testWidgets('backgrounded, it waits; back in the app, it sends at once', (
      t,
    ) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await sendText(t, 'one');
      await settle(t);
      w.chat.fail(0, offline);
      await settle(t);

      await background(t);
      await t.pump(const Duration(minutes: 2));
      expect(w.chat.asked, hasLength(1), reason: 'no retry while hidden');

      await foreground(t);
      await t.pump();
      await t.pump();
      expect(w.chat.asked, hasLength(2), reason: 'retried on return');
      expect(w.chat.asked[1].id, w.chat.asked[0].id);
      w.chat.ok(1);
      await settle(t);
      expect(clock, findsNothing);
    });
  });

  group('a refused send', () {
    testWidgets('with the chat open: the text comes back with one notice', (
      t,
    ) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await sendText(t, 'one');
      await sendText(t, 'two');
      await settle(t);
      w.chat.fail(0, refused);
      await settle(t);

      expect(composerText(t), 'one\ntwo');
      expect(clock, findsNothing);
      expect(notice, findsOneWidget);
      await drainNotice(t);
      expect(notice, findsNothing);
    });

    testWidgets('after leaving: the list shows no draft, and opening the '
        'chat puts the text back with one notice, once', (t) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await sendText(t, 'one');
      await settle(t);
      await back(t);
      w.chat.fail(0, refused);
      await settle(t);

      expect(draftPreview('c1'), findsNothing);
      expect(
        find.textContaining('Draft', findRichText: true),
        findsNothing,
        reason: 'the list shows no draft (owner, v0.21.4)',
      );
      expect(notice, findsNothing, reason: 'shown in the chat, not the list');

      await openChat(t, 'c1');
      expect(composerText(t), 'one');
      expect(notice, findsOneWidget);
      await drainNotice(t);
      await back(t);
      await openChat(t, 'c1');
      expect(notice, findsNothing, reason: 'the notice is shown once');
      expect(composerText(t), 'one', reason: 'the text stays');
    });

    testWidgets('a refusal in one chat never touches another', (t) async {
      final w = World();
      await start(t, w);
      await openChat(t, 'c1');
      await sendText(t, 'to bob');
      await settle(t);
      await back(t);
      await openChat(t, 'c2');
      await sendText(t, 'to cem');
      await settle(t);
      expect(w.chat.asked, hasLength(2), reason: 'c2 did not wait for c1');

      w.chat.fail(0, refused);
      await settle(t);
      expect(notice, findsNothing, reason: 'c1\'s notice waits for c1');
      expect(composerText(t), isEmpty);
      w.chat.ok(1);
      await settle(t);
      expect(clock, findsNothing);
      expect(bubble(w.chat.asked[1].id), findsOneWidget);
    });
  });
}
