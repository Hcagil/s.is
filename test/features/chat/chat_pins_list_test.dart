import 'dart:async';

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
import '../../support/pin_fakes.dart';
import '../../support/sis_ui.dart' as ui;
import '../../support/video_fakes.dart';

const config = RuntimeConfig(
  supabaseUrl: 'https://x.supabase.co',
  supabasePublishableKey: 'k',
  googleWebClientId: 'c',
);
const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'ub', displayName: 'Bob Stone');
const cem = Member(userId: 'uc', displayName: 'Cem Ak');

Finder byKey(String key) => find.byKey(ValueKey(key));

/// The text of header [key], case-folded: a header may draw its label in
/// capitals (Turkish dotted/dotless i folded too).
String headerText(WidgetTester t, String key) => find
    .descendant(of: byKey(key), matching: find.byType(Text))
    .evaluate()
    .map((e) => (e.widget as Text).data ?? '')
    .join()
    .replaceAll('İ', 'I')
    .replaceAll('ı', 'i')
    .toLowerCase();

// Headers are keyed by their place in the list: `list-header-0` above the
// pinned chats, `list-header-<pinned count + 1>` above the rest.

/// Builds a list of conversations. `ids` determines which chats are present.
List<Conversation> list({
  bool c1Archived = false,
  Set<String> pinned = const {},
  List<String> ids = const ['c1', 'c2'],
}) {
  final now = DateTime.now().toUtc();
  return ids.map((id) {
    final other = id == 'c1'
        ? bob
        : id == 'c2'
        ? cem
        : bob;
    return Conversation(
      id: id,
      other: other,
      lastMessage: 'hi',
      lastMessageAt: now.subtract(Duration(minutes: ids.indexOf(id))),
      lastSenderId: other.userId,
      unread: 0,
      archived: id == 'c1' ? c1Archived : false,
      pinned: pinned.contains(id),
    );
  }).toList();
}

Future<NotificationSettingsFake> pumpList(
  WidgetTester t, {
  List<Mute> mutes = const [],
  ChatFake? chat,
  ChatArchiveFake? archive,
  int unread = 0,
  ChatPinFake? pins,
}) async {
  final notif = NotificationSettingsFake(
    mutes: mutes,
    latency: const Duration(milliseconds: 40),
  );
  await t.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('screen'),
      child: ProviderScope(
        overrides: [
          ...videoOverrides(),
          runtimeConfigProvider.overrideWithValue(config),
          authRepositoryProvider.overrideWithValue(
            FakeAuth(session: true, member: me),
          ),
          updateRepositoryProvider.overrideWithValue(FakeUpdate()),
          chatRepositoryProvider.overrideWithValue(
            chat ?? (ChatFake()..conversationsResult = Ok(list())),
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
          chatPinRepositoryProvider.overrideWithValue(pins ?? ChatPinFake()),
          chatDeleteRepositoryProvider.overrideWithValue(ChatDeleteFake()),
        ],
        child: const SisApp(),
      ),
    ),
  );
  await t.pumpAndSettle();
  return notif;
}

Future<void> commit(WidgetTester t, String id) async {
  final g = await t.startGesture(t.getCenter(byKey('archive-swipe-$id')));
  for (var i = 0; i < 10; i++) {
    await g.moveBy(const Offset(-10, 0));
    await t.pump(const Duration(milliseconds: 16));
  }
  await g.up();
}

Future<TestGesture> partial(WidgetTester t, String id) async {
  final g = await t.startGesture(t.getCenter(byKey('archive-swipe-$id')));
  for (var i = 0; i < 4; i++) {
    await g.moveBy(const Offset(-10, 0));
    await t.pump(const Duration(milliseconds: 16));
  }
  return g;
}

Finder archivedRow() =>
    find.byKey(const ValueKey('archived-chats-row'), skipOffstage: false);

Future<void> openArchived(WidgetTester t) async {
  await t.drag(byKey('conversation-list'), const Offset(0, 120));
  await t.pumpAndSettle();
  await t.tap(byKey('archived-chats-row'));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('pinned chats appear first', (WidgetTester t) async {
    await pumpList(
      t,
      chat: ChatFake()..conversationsResult = Ok(list(pinned: {'c2'})),
    );
    final header0 = byKey('list-header-0');
    final header1 = byKey('list-header-2');
    final c2 = byKey('conversation-c2');
    final c1 = byKey('conversation-c1');
    expect(header0, findsOneWidget);
    expect(header1, findsOneWidget);
    expect(c2, findsOneWidget);
    expect(c1, findsOneWidget);
    expect(headerText(t, 'list-header-0'), 'pinned');
    expect(headerText(t, 'list-header-2'), 'chats');
    expect(find.byKey(const ValueKey('pinned-c2')), findsOneWidget);
    expect(find.byKey(const ValueKey('pinned-c1')), findsNothing);
    expect(t.getTopLeft(header0).dy, lessThan(t.getTopLeft(c2).dy));
    expect(t.getTopLeft(c2).dy, lessThan(t.getTopLeft(header1).dy));
    expect(t.getTopLeft(header1).dy, lessThan(t.getTopLeft(c1).dy));
  });

  testWidgets('pinning is optimistic', (WidgetTester t) async {
    final pins = ChatPinFake()..hold = Completer<void>();
    await pumpList(t, pins: pins);
    await t.longPress(byKey('conversation-c2'));
    await t.pumpAndSettle();
    expect(find.byTooltip('Pin'), findsOneWidget);
    await t.tap(byKey('selection-pin'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('pinned-c2')), findsOneWidget);
    expect(
      t.getTopLeft(byKey('conversation-c2')).dy,
      lessThan(t.getTopLeft(byKey('conversation-c1')).dy),
    );
    expect(pins.calls, equals(['chat:c2:true']));
    pins.hold!.complete();
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pinned-c2')), findsOneWidget);
  });

  testWidgets('unpinning works', (WidgetTester t) async {
    final pins = ChatPinFake(pinned: {'c2'});
    await pumpList(
      t,
      chat: ChatFake()..conversationsResult = Ok(list(pinned: {'c2'})),
      pins: pins,
    );
    await t.longPress(byKey('conversation-c2'));
    await t.pumpAndSettle();
    expect(find.byTooltip('Unpin chat'), findsOneWidget);
    await t.tap(byKey('selection-pin'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pinned-c2')), findsNothing);
    expect(pins.calls, equals(['chat:c2:false']));
    expect(
      t.getTopLeft(byKey('conversation-c1')).dy,
      lessThan(t.getTopLeft(byKey('conversation-c2')).dy),
    );
  });

  testWidgets('6th pin shows notice and does not pin', (WidgetTester t) async {
    // A tall phone, so all six rows are on screen.
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final pins = ChatPinFake(pinned: {'p1', 'p2', 'p3', 'p4', 'p5'});
    await pumpList(
      t,
      chat: ChatFake()
        ..conversationsResult = Ok(
          list(
            ids: ['p1', 'p2', 'p3', 'p4', 'p5', 'c6'],
            pinned: {'p1', 'p2', 'p3', 'p4', 'p5'},
          ),
        ),
      pins: pins,
    );
    await t.longPress(byKey('conversation-c6'));
    await t.pumpAndSettle();
    expect(find.byTooltip('Pin'), findsOneWidget);
    await t.tap(byKey('selection-pin'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('You can pin up to 5 chats.'), findsOneWidget);
    expect(pins.calls, isEmpty);
    expect(find.byKey(const ValueKey('pinned-c6')), findsNothing);
    await ui.drainNotice(t);
  });

  testWidgets('server limit failure shows notice and reverts', (
    WidgetTester t,
  ) async {
    final pins = ChatPinFake();
    pins.writeResult = const Err(PinLimitFailure());
    await pumpList(t, pins: pins);
    await t.longPress(byKey('conversation-c1'));
    await t.pumpAndSettle();
    expect(find.byTooltip('Pin'), findsOneWidget);
    await t.tap(byKey('selection-pin'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pinned-c1')), findsNothing);
    expect(find.text('You can pin up to 5 chats.'), findsOneWidget);
    await ui.drainNotice(t);
  });

  testWidgets('denied failure shows notice and reverts', (
    WidgetTester t,
  ) async {
    final pins = ChatPinFake();
    pins.writeResult = const Err(DeniedFailure());
    await pumpList(t, pins: pins);
    await t.longPress(byKey('conversation-c1'));
    await t.pumpAndSettle();
    expect(find.byTooltip('Pin'), findsOneWidget);
    await t.tap(byKey('selection-pin'));
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('pinned-c1')), findsNothing);
    expect(ui.notice, findsOneWidget);
    await ui.drainNotice(t);
  });

  testWidgets('archived screen has no pin menu', (WidgetTester t) async {
    await pumpList(
      t,
      chat: ChatFake()..conversationsResult = Ok(list(c1Archived: true)),
      archive: ChatArchiveFake(archived: {'c1'}),
    );
    await openArchived(t);
    await t.longPress(byKey('conversation-c1'));
    await t.pumpAndSettle();
    // The Archived screen keeps its own menu; it does not select.
    expect(byKey('chat-menu'), findsOneWidget);
    expect(find.byKey(const ValueKey('chat-menu-pin')), findsNothing);
    expect(byKey('selection-pin'), findsNothing);
  });

  testWidgets('failed archive keeps pin', (WidgetTester t) async {
    final pins = ChatPinFake(pinned: {'c1'});
    final archive = ChatArchiveFake()
      ..result = const Err(NetworkFailure('offline'));
    await pumpList(
      t,
      chat: ChatFake()..conversationsResult = Ok(list(pinned: {'c1'})),
      pins: pins,
      archive: archive,
    );
    await commit(t, 'c1');
    await t.pumpAndSettle();
    expect(find.byKey(const ValueKey('conversation-c1')), findsOneWidget);
    expect(find.byKey(const ValueKey('pinned-c1')), findsOneWidget);
    expect(
      t.getTopLeft(byKey('list-header-0')).dy,
      lessThan(t.getTopLeft(byKey('conversation-c1')).dy),
    );
    await ui.drainNotice(t);
  });

  testWidgets('archiving a pinned chat frees its pin slot', (
    WidgetTester t,
  ) async {
    t.view.physicalSize = const Size(1080, 2400);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    final pins = ChatPinFake(pinned: {'p1', 'p2', 'p3', 'p4', 'p5'});
    await pumpList(
      t,
      chat: ChatFake()
        ..conversationsResult = Ok(
          list(
            ids: ['p1', 'p2', 'p3', 'p4', 'p5', 'c6'],
            pinned: {'p1', 'p2', 'p3', 'p4', 'p5'},
          ),
        ),
      pins: pins,
      archive: ChatArchiveFake(),
    );
    await commit(t, 'p1');
    await t.pumpAndSettle();
    // The server's chat_archives_unpin trigger dropped p1's pin.
    pins.pinned.remove('p1');
    await t.longPress(byKey('conversation-c6'));
    await t.pumpAndSettle();
    await t.tap(byKey('selection-pin'));
    await t.pumpAndSettle();
    expect(find.text('You can pin up to 5 chats.'), findsNothing);
    expect(pins.calls, contains('chat:c6:true'));
    expect(byKey('pinned-c6'), findsOneWidget);
  });

  testWidgets('the server pin limit in Turkish', (WidgetTester t) async {
    t.platformDispatcher.localesTestValue = [const Locale('tr')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    final pins = ChatPinFake()..writeResult = const Err(PinLimitFailure());
    await pumpList(t, pins: pins);
    await t.longPress(byKey('conversation-c1'));
    await t.pumpAndSettle();
    await t.tap(byKey('selection-pin'));
    await t.pumpAndSettle();
    expect(find.text('En fazla 5 sohbet sabitleyebilirsin.'), findsOneWidget);
    expect(byKey('pinned-c1'), findsNothing);
    await ui.drainNotice(t);
  });

  testWidgets('Turkish labels', (WidgetTester t) async {
    t.platformDispatcher.localesTestValue = [const Locale('tr')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
    await pumpList(
      t,
      chat: ChatFake()..conversationsResult = Ok(list(pinned: {'c2'})),
    );
    expect(headerText(t, 'list-header-0'), 'sabitlenenler');
    expect(headerText(t, 'list-header-2'), 'sohbetler');
    await t.longPress(byKey('conversation-c1'));
    await t.pumpAndSettle();
    expect(find.byTooltip('Sabitle'), findsOneWidget);
  });
}
