import 'dart:async';

import 'package:flutter/material.dart' show Locale, ValueKey;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart'
    show chatPinRepositoryProvider;
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/domain/group_member.dart';
import 'package:sis/features/chat/domain/group_settings.dart';
import 'package:sis/features/chat/domain/message.dart'
    show Message, MessageAction;
import 'package:sis/features/chat/domain/sticker.dart' show starterStickerIds;
import 'package:sis/features/chat/presentation/swipeable_message.dart'
    show swipeActionKeyId;

import '../../support/pin_fakes.dart';
import '../../support/sis_ui.dart' show notice, drainNotice;
import 'profile_pages_test.dart'
    show
        World,
        withBob,
        me,
        bob,
        cem,
        m,
        byKey,
        settle,
        pumpApp,
        reveal,
        tapKey,
        openChat,
        clubPage;

List<Override> pinWith(ChatPinFake p) => [
  chatPinRepositoryProvider.overrideWithValue(p),
];

void roster(World w, {required bool admin}) {
  w.chat.groupRosters['g1'] = [
    GroupMember(member: me, isAdmin: admin),
    GroupMember(member: bob, isAdmin: !admin, colorSlot: 1),
    const GroupMember(member: cem, isAdmin: false, colorSlot: 2),
  ];
}

void pinT1(World w, ChatPinFake p) {
  w.chat.conversationsResult = Ok([
    withBob.withPinnedMessage('t1'),
    const Conversation(id: 'g1', title: 'Club', lastMessage: 'yo'),
  ]);
  p.messages['t1'] = m(
    't1',
    'c1',
    'ub',
    DateTime.utc(2026, 9, 20, 13),
    body: 'plain text',
  );
}

void main() {
  testWidgets('the bar shows the pinned message', (t) async {
    final pins = ChatPinFake();
    final w = World(self: 'u1', extra: pinWith(pins));
    pinT1(w, pins);
    await pumpApp(t, w);
    await openChat(t, 'c1');
    expect(byKey('pinned-bar'), findsOneWidget);
    expect(
      find.descendant(
        of: byKey('pinned-bar-text'),
        matching: find.textContaining('plain text'),
        matchRoot: true,
      ),
      findsOneWidget,
    );
  });

  // Contract (stickers 10a): a pinned sticker shows as a sticker in the
  // banner (its image or the sticker preview line), never as a photo or
  // an empty text line.
  testWidgets('a pinned sticker shows as a sticker in the bar', (t) async {
    final pins = ChatPinFake();
    final w = World(self: 'u1', extra: pinWith(pins));
    pinT1(w, pins);
    pins.messages['t1'] = Message(
      id: 't1',
      conversationId: 'c1',
      senderId: 'ub',
      body: '',
      createdAt: DateTime.utc(2026, 9, 20, 13),
      stickerId: starterStickerIds.first,
    );
    await pumpApp(t, w);
    await openChat(t, 'c1');
    expect(byKey('pinned-bar'), findsOneWidget);
    Finder inBar(Finder f) =>
        find.descendant(of: byKey('pinned-bar'), matching: f);
    expect(
      inBar(find.text('Photo')),
      findsNothing,
      reason: 'a sticker is not a photo',
    );
    final asSticker =
        inBar(find.textContaining('Sticker')).evaluate().isNotEmpty ||
        inBar(
          find.byWidgetPredicate(
            (x) =>
                x.key is ValueKey<String> &&
                (x.key! as ValueKey<String>).value.startsWith('sticker-'),
          ),
        ).evaluate().isNotEmpty;
    expect(
      asSticker,
      isTrue,
      reason: 'the bar shows the sticker image or the sticker line',
    );
  });

  testWidgets('no bar when the message cannot be fetched', (t) async {
    final pins = ChatPinFake();
    final w = World(self: 'u1', extra: pinWith(pins));
    pinT1(w, pins);
    pins.messages.clear();
    await pumpApp(t, w);
    await openChat(t, 'c1');
    expect(byKey('pinned-bar'), findsNothing);
  });

  testWidgets('tapping the bar jumps to the message', (t) async {
    final pins = ChatPinFake();
    final w = World(self: 'u1', extra: pinWith(pins));
    // Add filler history
    w.chat.history['c1']!.addAll(
      List.generate(
        40,
        (i) => m(
          'f$i',
          'c1',
          'ub',
          DateTime.utc(2026, 9, 22, 0, i),
          body: 'filler $i',
        ),
      ),
    );
    pinT1(w, pins);
    await pumpApp(t, w);
    await openChat(t, 'c1');
    expect(byKey('message-t1').hitTestable(), findsNothing);
    await t.tap(byKey('pinned-bar'));
    await settle(t);
    expect(byKey('message-t1').hitTestable(), findsOneWidget);
  });

  testWidgets('pinning shows the bar before the server answers', (t) async {
    final pins = ChatPinFake();
    final w = World(self: 'u1', extra: pinWith(pins));
    pins.hold = Completer<void>();
    await pumpApp(t, w);
    await openChat(t, 'c1');
    await t.longPress(byKey('message-t1'));
    await settle(t);
    await t.tap(byKey('menu-pin'));
    // The server is held: whatever shows now is the optimistic state.
    await t.pump(const Duration(milliseconds: 100));
    expect(byKey('pinned-bar'), findsOneWidget);
    expect(pins.calls, contains('message:c1:t1'));
    pins.hold!.complete();
    await settle(t);
    expect(byKey('pinned-bar'), findsOneWidget);
  });

  testWidgets('unpinning removes the bar', (t) async {
    final pins = ChatPinFake();
    final w = World(self: 'u1', extra: pinWith(pins));
    pinT1(w, pins);
    await pumpApp(t, w);
    await openChat(t, 'c1');
    await t.longPress(byKey('message-t1'));
    await settle(t);
    expect(byKey('menu-unpin'), findsOneWidget);
    expect(byKey('menu-pin'), findsNothing);
    await t.tap(byKey('menu-unpin'));
    await settle(t);
    expect(byKey('pinned-bar'), findsNothing);
    expect(pins.calls, contains('message:c1:-'));
  });

  testWidgets('a refused pin reverts with a notice', (t) async {
    final pins = ChatPinFake();
    final w = World(self: 'u1', extra: pinWith(pins));
    pins.writeResult = const Err(DeniedFailure());
    await pumpApp(t, w);
    await openChat(t, 'c1');
    await t.longPress(byKey('message-t1'));
    await settle(t);
    await t.tap(byKey('menu-pin'));
    await settle(t);
    expect(byKey('pinned-bar'), findsNothing);
    expect(notice, findsOneWidget);
    await drainNotice(t);
  });

  testWidgets('switch off: a member gets no pin row', (t) async {
    final pins = ChatPinFake();
    final w = World(
      self: 'u1',
      settings: const GroupSettings(membersCanPin: false),
      extra: pinWith(pins),
    );
    roster(w, admin: false);
    await pumpApp(t, w);
    await openChat(t, 'g1');
    await t.longPress(byKey('message-gt'));
    await settle(t);
    expect(byKey('menu-pin'), findsNothing);
  });

  testWidgets('switch off: an admin may pin', (t) async {
    final pins = ChatPinFake();
    final w = World(
      self: 'u1',
      settings: const GroupSettings(membersCanPin: false),
      extra: pinWith(pins),
    );
    roster(w, admin: true);
    await pumpApp(t, w);
    await openChat(t, 'g1');
    await t.longPress(byKey('message-gt'));
    await settle(t);
    expect(byKey('menu-pin'), findsOneWidget);
  });

  testWidgets('a pin event shows a line', (t) async {
    final pins = ChatPinFake();
    final w = World(self: 'u1', extra: pinWith(pins));
    pins.events['c1'] = [
      GroupEvent(
        id: 'e1',
        conversationId: 'c1',
        kind: GroupEventKind.pinned,
        subjectId: 'ub',
        actorId: 'ub',
        createdAt: DateTime.utc(2026, 9, 20, 13, 30),
      ),
    ];
    await pumpApp(t, w);
    await openChat(t, 'c1');
    expect(find.textContaining('Bob Stone pinned a message'), findsOneWidget);
  });

  testWidgets('admin chooses who may pin', (t) async {
    final pins = ChatPinFake();
    final w = World(self: 'u1', extra: pinWith(pins));
    roster(w, admin: true);
    await pumpApp(t, w);
    await clubPage(t, w);
    await tapKey(t, 'setting-membersCanPin');
    expect(byKey('pin-who-card'), findsOneWidget);
    expect(byKey('menu-pin-all'), findsOneWidget);
    expect(byKey('menu-pin-admins'), findsOneWidget);
    await tapKey(t, 'menu-pin-admins');
    await settle(t);
    expect(pins.calls.where((c) => c.startsWith('who:')).toList(), [
      'who:g1:false',
    ]);
  });

  testWidgets('a member sees the setting greyed', (t) async {
    final pins = ChatPinFake();
    final w = World(self: 'u1', extra: pinWith(pins));
    roster(w, admin: false);
    await pumpApp(t, w);
    await clubPage(t, w);
    await reveal(t, byKey('grey-p_who'));
    expect(byKey('grey-p_who'), findsOneWidget);
    expect(byKey('pin-who-card'), findsNothing);
  });
  testWidgets('the pin line in Turkish', (t) async {
    final pins = ChatPinFake();
    final w = World(self: 'u1', extra: pinWith(pins));
    pins.events['c1'] = [
      GroupEvent(
        id: 'e1',
        conversationId: 'c1',
        kind: GroupEventKind.pinned,
        subjectId: 'ub',
        actorId: 'ub',
        createdAt: DateTime.utc(2026, 9, 20, 13, 30),
      ),
    ];
    await pumpApp(t, w);
    // Home opens in English (pumpApp waits for it); then switch.
    t.platformDispatcher.localesTestValue = [const Locale('tr')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    await t.pumpAndSettle();
    await openChat(t, 'c1');
    expect(
      find.textContaining('Bob Stone bir mesajı sabitledi'),
      findsOneWidget,
    );
    expect(find.textContaining('pinned a message'), findsNothing);
  });

  test('swipe action ids for pin and unpin', () {
    expect(swipeActionKeyId(MessageAction.pin), 'pin');
    expect(swipeActionKeyId(MessageAction.unpin), 'unpin');
  });
}
