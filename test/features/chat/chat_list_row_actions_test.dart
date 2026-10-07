// The chat list rows of Update 1 slice 4, mounted as production mounts them
// (SisApp, the real controllers) with fakes only at the repositories:
// the muted bell and unread badge, long-press selection, the mute menu from the selection bar and its mute
// lengths, the inert grey pin, the archive swipe that archives past its
// commit line and springs back before it, and the back swipe that leaves the
// list still.
//
// Written from the contract (keys, MuteLength, mutesProvider), not the code.
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/archive_fakes.dart';
import '../../support/chat_delete_fakes.dart';
import '../../support/fakes.dart';
import '../../support/sis_ui.dart' as ui;

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone');
const cem = Member(userId: 'uc', displayName: 'Cem Ak');

Finder byKey(String key) => find.byKey(ValueKey(key));

/// Two chats: c1 with Bob, c2 with Cem, each with [unread] messages unread.
List<Conversation> chats({int unread = 0}) {
  final now = DateTime.now().toUtc();
  return [
    Conversation(
      id: 'c1',
      other: bob,
      lastMessage: 'hi',
      lastMessageAt: now.subtract(const Duration(minutes: 1)),
      lastSenderId: bob.userId,
      unread: unread,
    ),
    Conversation(
      id: 'c2',
      other: cem,
      lastMessage: 'yo',
      lastMessageAt: now.subtract(const Duration(minutes: 2)),
      lastSenderId: cem.userId,
      unread: unread,
    ),
  ];
}

Mute convMute(String id, {Duration? left}) => Mute(
  kind: MuteKind.conversation,
  target: id,
  until: left == null ? null : DateTime.now().add(left),
);

Future<NotificationSettingsFake> pumpList(
  WidgetTester t, {
  List<Mute> mutes = const [],
  ChatFake? chat,
  ChatArchiveFake? archive,
  int unread = 0,
}) async {
  // A save is not instant: the bell must follow the saved mute, not a guess.
  final notif = NotificationSettingsFake(
    mutes: mutes,
    latency: const Duration(milliseconds: 40),
  );
  await t.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('screen'),
      child: ProviderScope(
        overrides: [
          runtimeConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(
            FakeAuth(session: true, member: me),
          ),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          chatRepositoryProvider.overrideWithValue(
            chat ??
                (ChatFake()..conversationsResult = Ok(chats(unread: unread))),
          ),
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
          notificationSettingsRepositoryProvider.overrideWithValue(notif),
          chatArchiveRepositoryProvider.overrideWithValue(
            archive ?? ChatArchiveFake(),
          ),
          pushSourceProvider.overrideWithValue(PushSourceFake()),
          pushRegistryProvider.overrideWithValue(PushRegistryFake()),
          notificationExplainerStoreProvider.overrideWithValue(
            NotificationExplainerStoreFake(shown: true),
          ),
          chatDeleteRepositoryProvider.overrideWithValue(ChatDeleteFake()),
        ],
        child: const SisApp(),
      ),
    ),
  );
  await t.pumpAndSettle();
  expect(byKey('conversation-c1'), findsOneWidget, reason: 'no list');
  return notif;
}

/// Every fill drawn inside [of]: solid colours and whether a gradient is
/// among them, from whichever box widget draws it.
({Set<Color> colors, bool gradient}) fills(WidgetTester t, Finder of) {
  final colors = <Color>{};
  var gradient = false;
  void deco(Decoration? d) {
    if (d is BoxDecoration) {
      if (d.color != null) colors.add(d.color!);
      if (d.gradient != null) gradient = true;
    } else if (d is ShapeDecoration) {
      if (d.color != null) colors.add(d.color!);
      if (d.gradient != null) gradient = true;
    }
  }

  final all = find.descendant(
    of: of,
    matching: find.byWidgetPredicate((_) => true),
    matchRoot: true,
  );
  for (final w in t.widgetList(all)) {
    switch (w) {
      case Container(:final decoration, :final color):
        deco(decoration);
        if (color != null) colors.add(color);
      case DecoratedBox(:final decoration):
        deco(decoration);
      case ColoredBox(:final color):
        colors.add(color);
      case Material(:final color):
        if (color != null) colors.add(color);
      case Ink(:final decoration):
        deco(decoration);
    }
  }
  return (colors: colors, gradient: gradient);
}

/// The mean colour of [of] as drawn on screen, whatever draws it (the row
/// itself, a lifted copy in an overlay, or a scrim around it).
Future<(int, int, int)> drawn(WidgetTester t, Finder of) async {
  final rect = t.getRect(of.first);
  final image = (await t.runAsync(
    () => captureImage(t.element(byKey('screen'))),
  ))!;
  final bytes = (await t.runAsync(
    () => image.toByteData(format: ImageByteFormat.rawRgba),
  ))!;
  final k = image.width / t.getSize(byKey('screen')).width;
  var r = 0, g = 0, b = 0, n = 0;
  for (var y = (rect.top * k).ceil(); y < (rect.bottom * k).floor(); y += 2) {
    for (var x = (rect.left * k).ceil(); x < (rect.right * k).floor(); x += 2) {
      final i = (y * image.width + x) * 4;
      r += bytes.getUint8(i);
      g += bytes.getUint8(i + 1);
      b += bytes.getUint8(i + 2);
      n++;
    }
  }
  image.dispose();
  return (r ~/ n, g ~/ n, b ~/ n);
}

int shift((int, int, int) a, (int, int, int) b) =>
    (a.$1 - b.$1).abs() + (a.$2 - b.$2).abs() + (a.$3 - b.$3).abs();

Color onSurfaceVariant(WidgetTester t) =>
    Theme.of(t.element(byKey('conversation-c1'))).colorScheme.onSurfaceVariant;

/// Long-press selects the row; the bar's mute button opens the mute menu.
Future<void> openMuteMenu(WidgetTester t, String id) async {
  await t.longPress(byKey('conversation-$id'));
  await t.pumpAndSettle();
  await t.tap(byKey('selection-mute'));
  await t.pumpAndSettle();
  expect(byKey('chat-menu'), findsOneWidget);
}

/// [openMuteMenu] and, if the mute lengths sit one step deeper, open them.
Future<void> openMuteOptions(WidgetTester t, String id) async {
  await openMuteMenu(t, id);
  if (byKey('chat-mute-off').evaluate().isEmpty &&
      byKey('chat-mute-oneHour').evaluate().isEmpty) {
    await t.tap(byKey('chat-menu-mute'));
    await t.pumpAndSettle();
  }
}

void expectNear(DateTime? until, Duration d, String why) {
  expect(until, isNotNull, reason: '$why: no end');
  expect(
    until!.difference(DateTime.now().add(d)).abs(),
    lessThan(const Duration(minutes: 1)),
    reason: why,
  );
}

void main() {
  group('the muted bell', () {
    testWidgets('a muted chat shows a grey bell under its time, read as '
        '"Muted"; an unmuted one shows none', (t) async {
      final sem = t.ensureSemantics();
      await pumpList(
        t,
        mutes: [convMute('c1', left: const Duration(hours: 2))],
      );

      expect(byKey('muted-c1'), findsOneWidget);
      expect(byKey('muted-c2'), findsNothing);
      expect(find.bySemanticsLabel(RegExp(r'\bMuted\b')), findsOneWidget);

      final time = t.getRect(byKey('preview-time-c1'));
      final bell = t.getRect(byKey('muted-c1'));
      expect(bell.top, greaterThanOrEqualTo(time.bottom - 1), reason: 'under');
      expect(
        bell.right > time.left && bell.left < time.right,
        isTrue,
        reason: 'not in the time column: bell $bell, time $time',
      );
      sem.dispose();
    });

    testWidgets('a muted chat with unread messages fits its row: time, bell '
        'and badge without overflow', (t) async {
      await pumpList(
        t,
        unread: 2,
        mutes: [convMute('c1', left: const Duration(hours: 2))],
      );
      expect(t.takeException(), isNull, reason: 'the row overflowed');
      expect(byKey('muted-c1'), findsOneWidget);
      expect(byKey('unread-c1'), findsOneWidget);
    });

    testWidgets('a muted chat with no message yet still shows the bell', (
      t,
    ) async {
      final chat = ChatFake()
        ..conversationsResult = Ok([
          ...chats(),
          const Conversation(id: 'c3', other: bob),
        ]);
      await pumpList(
        t,
        chat: chat,
        mutes: [convMute('c3', left: const Duration(hours: 2))],
      );
      expect(byKey('conversation-c3'), findsOneWidget);
      expect(byKey('muted-c3'), findsOneWidget, reason: 'looks unmuted');
    });

    testWidgets('a forever mute (no end) still shows the bell', (t) async {
      await pumpList(t, mutes: [convMute('c1')]);
      expect(byKey('muted-c1'), findsOneWidget);
    });

    testWidgets('an expired mute shows no bell', (t) async {
      await pumpList(
        t,
        mutes: [convMute('c1', left: const Duration(minutes: -5))],
      );
      expect(byKey('muted-c1'), findsNothing);
    });

    testWidgets('the unread badge is solid onSurfaceVariant when muted, a '
        'gradient otherwise', (t) async {
      // Smaller text keeps this test about colour: the overflow a muted row
      // with unread messages has at 1.0 is the test above.
      t.platformDispatcher.textScaleFactorTestValue = 0.8;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpList(
        t,
        unread: 2,
        mutes: [convMute('c1', left: const Duration(hours: 2))],
      );
      final grey = onSurfaceVariant(t);

      final muted = fills(t, byKey('unread-c1'));
      expect(muted.gradient, isFalse, reason: 'muted: still a gradient');
      expect(muted.colors, contains(grey), reason: '${muted.colors}');

      final loud = fills(t, byKey('unread-c2'));
      expect(loud.gradient, isTrue, reason: 'unmuted: no gradient');
      expect(loud.colors, isNot(contains(grey)));
    });

    testWidgets('Turkish: the bell reads "Sessiz"', (t) async {
      t.platformDispatcher.localesTestValue = const [Locale('tr')];
      addTearDown(t.platformDispatcher.clearLocalesTestValue);
      final sem = t.ensureSemantics();
      await pumpList(
        t,
        mutes: [convMute('c1', left: const Duration(hours: 2))],
      );
      expect(find.bySemanticsLabel(RegExp(r'\bSessiz\b')), findsOneWidget);
      sem.dispose();
    });
  });

  group('the selection bar chat actions', () {
    testWidgets('long-press selects and lights the row; back puts the row '
        'back', (t) async {
      await pumpList(t);
      final row = byKey('conversation-c2');
      final other = byKey('conversation-c1');
      final before = await drawn(t, row);
      final otherBefore = await drawn(t, other);

      await t.longPress(row);
      await t.pumpAndSettle();
      expect(byKey('selection-count'), findsOneWidget);
      // Lit = the selected row changes more than an unselected one.
      final rowShift = shift(before, await drawn(t, row));
      final otherShift = shift(otherBefore, await drawn(t, other));
      expect(
        rowShift,
        greaterThan(otherShift),
        reason: 'the row is not lit: row $rowShift, other $otherShift',
      );

      await t.tap(byKey('selection-back'));
      await t.pumpAndSettle();
      expect(byKey('selection-count'), findsNothing);
      expect(await drawn(t, row), before, reason: 'still lit after back');
    });

    testWidgets('Mute expands to the five lengths, no Always and no Unmute; '
        'picking one mutes the conversation and the bell appears', (t) async {
      final notif = await pumpList(t);
      await openMuteMenu(t, 'c2');
      expect(byKey('chat-mute-off'), findsNothing, reason: 'not muted');
      await t.tap(byKey('chat-menu-mute'));
      await t.pumpAndSettle();
      for (final l in MuteLength.values) {
        expect(byKey('chat-mute-${l.name}'), findsOneWidget, reason: l.name);
      }
      expect(byKey('chat-mute-always'), findsNothing);
      expect(find.text('Always'), findsNothing);
      expect(byKey('chat-mute-off'), findsNothing, reason: 'not muted');

      await t.tap(byKey('chat-mute-eightHours'));
      await t.pumpAndSettle();
      expect(byKey('chat-menu'), findsNothing);
      final (kind, target, until) = notif.muteCalls.single;
      expect(kind, MuteKind.conversation);
      expect(target, 'c2');
      expectNear(until, const Duration(hours: 8), '8 hours');
      expect(byKey('muted-c2'), findsOneWidget);
      expect(byKey('muted-c1'), findsNothing);
      expect(notif.unmuteCalls, isEmpty);
    });

    for (final (l, d) in [
      (MuteLength.oneHour, const Duration(hours: 1)),
      (MuteLength.oneDay, const Duration(days: 1)),
      (MuteLength.threeDays, const Duration(days: 3)),
      (MuteLength.oneWeek, const Duration(days: 7)),
    ]) {
      testWidgets('${l.name} mutes for $d', (t) async {
        final notif = await pumpList(t);
        await openMuteOptions(t, 'c1');
        await t.tap(byKey('chat-mute-${l.name}'));
        await t.pumpAndSettle();
        expect(notif.muteCalls.single.$2, 'c1');
        expectNear(notif.muteCalls.single.$3, d, l.name);
      });
    }

    testWidgets('on a muted chat the bar offers Unmute; it unmutes the '
        'conversation and the bell goes', (t) async {
      final notif = await pumpList(
        t,
        mutes: [convMute('c1', left: const Duration(hours: 2))],
      );
      await t.longPress(byKey('conversation-c1'));
      await t.pumpAndSettle();
      expect(
        find.descendant(
          of: byKey('selection-mute'),
          matching: find.byTooltip('Unmute'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
      await t.tap(byKey('selection-mute'));
      await t.pumpAndSettle();
      expect(notif.unmuteCalls, [(MuteKind.conversation, 'c1')]);
      expect(notif.muteCalls, isEmpty);
      expect(byKey('muted-c1'), findsNothing);
      expect(byKey('chat-menu'), findsNothing);
    });

    testWidgets('an unmute the server refuses shows a notice and the bell '
        'stays', (t) async {
      final notif = await pumpList(
        t,
        mutes: [convMute('c1', left: const Duration(hours: 2))],
      );
      notif.unmuteResult = const Err(NetworkFailure('offline'));
      await t.longPress(byKey('conversation-c1'));
      await t.pumpAndSettle();
      await t.tap(byKey('selection-mute'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(ui.notice, findsOneWidget, reason: 'the failure was swallowed');
      expect(byKey('muted-c1'), findsOneWidget);
      await ui.drainNotice(t);
    });

    testWidgets('the bar offers Pin, no grey pin', (t) async {
      await pumpList(t);
      await t.longPress(byKey('conversation-c2'));
      await t.pumpAndSettle();
      expect(byKey('selection-pin'), findsOneWidget);
      expect(
        find.descendant(
          of: byKey('selection-pin'),
          matching: find.byTooltip('Pin'),
          matchRoot: true,
        ),
        findsOneWidget,
      );
      expect(byKey('grey-pin'), findsNothing);
      expect(find.textContaining('soon'), findsNothing);
    });
  });

  group('the archive swipe', () {
    testWidgets(
      'a left drag moves the row at most 120 px and shows the archive pill',
      (t) async {
        await pumpList(t);
        final x0 = t.getTopLeft(byKey('conversation-c1')).dx;
        expect(byKey('archive-pill-c1'), findsNothing);

        final g = await t.startGesture(t.getCenter(byKey('archive-swipe-c1')));
        // 30 steps of -10 px = -300 px, should cap at -120 px
        for (var i = 0; i < 30; i++) {
          await g.moveBy(const Offset(-10, 0));
          await t.pump(const Duration(milliseconds: 16));
        }
        expect(t.getTopLeft(byKey('conversation-c1')).dx, equals(x0 - 120));
        expect(byKey('archive-pill-c1'), findsOneWidget);
        expect(
          find.descendant(
            of: byKey('archive-pill-c1'),
            matching: find.text('Archive'),
          ),
          findsOneWidget,
        );

        await g.up();
        await t.pumpAndSettle();
      },
    );

    testWidgets('dragging from 0 to 100 px triggers exactly one heavy haptic', (
      t,
    ) async {
      final haptics = <String?>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String?);
          }
          return null;
        },
      );

      await pumpList(t);
      final g = await t.startGesture(t.getCenter(byKey('archive-swipe-c1')));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(-10, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(haptics, equals(['HapticFeedbackType.heavyImpact']));

      await g.up();
      await t.pumpAndSettle();

      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    testWidgets('dragging from 0 to 50 px triggers no haptic', (t) async {
      final haptics = <String?>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            haptics.add(call.arguments as String?);
          }
          return null;
        },
      );

      await pumpList(t);
      final g = await t.startGesture(t.getCenter(byKey('archive-swipe-c1')));
      for (var i = 0; i < 5; i++) {
        await g.moveBy(const Offset(-10, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(haptics, isEmpty);

      await g.up();
      await t.pumpAndSettle();

      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    testWidgets('release past 70 commits archives', (t) async {
      final archive = ChatArchiveFake();
      await pumpList(t, archive: archive);

      final g = await t.startGesture(t.getCenter(byKey('archive-swipe-c1')));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(-10, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await t.pumpAndSettle();

      expect(
        archive.calls.map((e) => (e.key, e.value)).toList(),
        equals([('c1', true)]),
      );
      expect(byKey('conversation-c1'), findsNothing);
      expect(byKey('conversation-c2'), findsOneWidget);
    });

    testWidgets('release before 70 springs back over 220 ms', (t) async {
      final archive = ChatArchiveFake();
      await pumpList(t, archive: archive);
      final x0 = t.getTopLeft(byKey('conversation-c1')).dx;

      final g = await t.startGesture(t.getCenter(byKey('archive-swipe-c1')));
      await g.moveBy(const Offset(-50, 0));
      await t.pump(const Duration(milliseconds: 16));
      await g.up();
      // The spring starts on the first frame after the release.
      await t.pump();

      await t.pump(const Duration(milliseconds: 100));
      expect(t.getTopLeft(byKey('conversation-c1')).dx, lessThan(x0));

      await t.pump(const Duration(milliseconds: 130));
      expect(t.getTopLeft(byKey('conversation-c1')).dx, equals(x0));

      expect(archive.calls, isEmpty);
      expect(byKey('archive-pill-c1'), findsNothing);
      expect(byKey('conversation-c1'), findsOneWidget);
    });

    testWidgets('a cancelled drag springs back and archives nothing', (
      t,
    ) async {
      final archive = ChatArchiveFake();
      await pumpList(t, archive: archive);
      final x0 = t.getTopLeft(byKey('conversation-c1')).dx;

      final g = await t.startGesture(t.getCenter(byKey('archive-swipe-c1')));
      await g.moveBy(const Offset(-20, 0));
      await t.pump(const Duration(milliseconds: 16));
      await g.moveBy(const Offset(-40, 0));
      await t.pump(const Duration(milliseconds: 16));
      expect(t.getTopLeft(byKey('conversation-c1')).dx, lessThan(x0));

      await g.cancel();
      await t.pumpAndSettle();

      expect(t.getTopLeft(byKey('conversation-c1')).dx, equals(x0));
      expect(byKey('archive-pill-c1'), findsNothing);
      expect(archive.calls, isEmpty);
    });

    testWidgets('a right drag shows no pill and does not push the row right', (
      t,
    ) async {
      await pumpList(t);
      final x0 = t.getTopLeft(byKey('conversation-c1')).dx;
      final g = await t.startGesture(t.getCenter(byKey('archive-swipe-c1')));
      for (var i = 0; i < 5; i++) {
        await g.moveBy(const Offset(30, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(byKey('archive-pill-c1'), findsNothing);
      expect(t.getTopLeft(byKey('conversation-c1')).dx, lessThanOrEqualTo(x0));
      await g.up();
      await t.pumpAndSettle();
    });

    testWidgets(
      'a left drag carried back past its start never pushes the row right',
      (t) async {
        await pumpList(t);
        final double x0 = t.getTopLeft(byKey('conversation-c1')).dx;
        final g = await t.startGesture(t.getCenter(byKey('archive-swipe-c1')));
        await g.moveBy(const Offset(-20, 0));
        await t.pump(const Duration(milliseconds: 16));
        await g.moveBy(const Offset(-40, 0));
        await t.pump(const Duration(milliseconds: 16));
        expect(
          t.getTopLeft(byKey('conversation-c1')).dx,
          lessThan(x0),
          reason: 'the drag started',
        );
        for (var i = 0; i <= 7; i++) {
          await g.moveBy(const Offset(30, 0));
          await t.pump(const Duration(milliseconds: 16));
          expect(
            t.getTopLeft(byKey('conversation-c1')).dx,
            lessThanOrEqualTo(x0),
            reason: 'pushed right at step $i',
          );
        }
        expect(byKey('archive-pill-c1'), findsNothing);
        await g.up();
        await t.pumpAndSettle();
        expect(t.getTopLeft(byKey('conversation-c1')).dx, equals(x0));
      },
    );
  });

  group('back swipe from a chat', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      testWidgets('${platform.name}: the list under a right drag does not '
          'move; the page transition delegates nothing', (t) async {
        debugDefaultTargetPlatformOverride = platform;
        try {
          await pumpList(t);
          final row = t.getTopLeft(byKey('conversation-c2'));
          await t.tap(byKey('conversation-c1'));
          await t.pumpAndSettle();
          expect(find.byType(MessageScreen), findsOneWidget);

          final g = await t.startGesture(Offset(2, row.dy + 20));
          for (var i = 0; i < 8; i++) {
            await g.moveBy(const Offset(20, 0));
            await t.pump(const Duration(milliseconds: 16));
          }
          final under = find.byKey(
            const ValueKey('conversation-c2'),
            skipOffstage: false,
          );
          expect(t.getTopLeft(under), row, reason: 'the list moved');
          // The chat page's transition builder delegates nothing to the
          // list (a MaterialPageRoute's own getter is a static trampoline to
          // the theme's builder, so the builder is what to ask).
          final theme = Theme.of(t.element(find.byType(MessageScreen)));
          expect(
            theme.pageTransitionsTheme.builders[platform]?.delegatedTransition,
            isNull,
          );
          await g.cancel();
          await t.pumpAndSettle();
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      });
    }
  });
}
