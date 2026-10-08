import 'dart:io';

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
import 'package:sis/features/notifications/application/notification_settings_controller.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/update/application/update_controller.dart';

import '../../support/archive_fakes.dart';
import '../../support/chat_delete_fakes.dart';
import '../../support/fakes.dart';
import '../../support/group_settings_fakes.dart';
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

List<Conversation> rows() {
  final now = DateTime.now().toUtc();
  Conversation at(int i, Conversation c) => Conversation(
    id: c.id,
    title: c.title,
    other: c.other,
    isAdmin: c.isAdmin,
    isSystem: c.isSystem,
    lastMessage: 'hi ${c.id}',
    lastMessageAt: now.subtract(Duration(minutes: i + 1)),
    lastSenderId: c.other?.userId,
  );
  return [
    at(0, const Conversation(id: 'c1', other: bob)),
    at(1, const Conversation(id: 'c2', other: cem)),
    at(2, const Conversation(id: 'g1', title: 'Trip')),
    at(3, const Conversation(id: 'g2', title: 'Club', isAdmin: true)),
    at(
      4,
      const Conversation(
        id: 's',
        isSystem: true,
        other: Member(userId: 'sys', displayName: 'SIS'),
      ),
    ),
  ];
}

typedef World = ({ChatFake chat, ChatDeleteFake del, GroupSettingsFake groups});

Future<World> pumpList(WidgetTester t, {bool tr = false}) async {
  if (tr) {
    t.platformDispatcher.localesTestValue = [const Locale('tr')];
    addTearDown(t.platformDispatcher.clearLocalesTestValue);
  }
  final chat = ChatFake()..conversationsResult = Ok(rows());
  final del = ChatDeleteFake(chat: chat);
  final groups = GroupSettingsFake(
    onDeleted: (id) {
      if (chat.conversationsResult case Ok(value: final all)) {
        chat.conversationsResult = Ok([
          for (final c in all)
            if (c.id != id) c,
        ]);
      }
    },
  );
  await t.pumpWidget(
    ProviderScope(
      overrides: [
        ...videoOverrides(),
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
        notificationSettingsRepositoryProvider.overrideWithValue(
          NotificationSettingsFake(),
        ),
        chatArchiveRepositoryProvider.overrideWithValue(ChatArchiveFake()),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        pushRegistryProvider.overrideWithValue(PushRegistryFake()),
        notificationExplainerStoreProvider.overrideWithValue(
          NotificationExplainerStoreFake(shown: true),
        ),
        chatPinRepositoryProvider.overrideWithValue(ChatPinFake()),
        chatDeleteRepositoryProvider.overrideWithValue(del),
        groupSettingsRepositoryProvider.overrideWithValue(groups),
      ],
      child: const SisApp(),
    ),
  );
  await t.pumpAndSettle();
  expect(byKey('conversation-c1'), findsOneWidget, reason: 'no list');
  return (chat: chat, del: del, groups: groups);
}

Future<void> select(WidgetTester t, List<String> ids) async {
  await t.longPress(byKey('conversation-${ids.first}'));
  await t.pumpAndSettle();
  for (final id in ids.skip(1)) {
    await t.tap(byKey('conversation-$id'));
    await t.pumpAndSettle();
  }
}

Future<void> openDelete(WidgetTester t, List<String> ids) async {
  await select(t, ids);
  await t.tap(byKey('selection-delete'));
  await t.pumpAndSettle();
}

Future<void> confirm(WidgetTester t, {bool tick = false}) async {
  if (tick) {
    await t.tap(byKey('delete-chat-check'));
    await t.pump();
  }
  await t.tap(byKey('delete-chat-ok'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

Future<void> runOut(WidgetTester t) async {
  for (var i = 0; i < 7; i++) {
    await t.pump(const Duration(seconds: 1));
  }
  await t.pumpAndSettle();
}

String count(WidgetTester t) =>
    t
        .widget<Text>(
          find.descendant(
            of: byKey('selection-count'),
            matching: find.byType(Text),
            matchRoot: true,
          ),
        )
        .data ??
    '';

Finder rich(String s) => find.byWidgetPredicate(
  (w) => w is RichText && w.text.toPlainText().contains(s),
);

bool boldShown(WidgetTester t, String s) {
  for (final r in t.widgetList<RichText>(find.byType(RichText))) {
    var found = false;
    r.text.visitChildren((span) {
      if (span is TextSpan &&
          (span.text ?? '').contains(s) &&
          (span.style?.fontWeight ?? FontWeight.normal).value >=
              FontWeight.w600.value) {
        found = true;
      }
      return !found;
    });
    if (found) return true;
  }
  return false;
}

List<String> order(WidgetTester t) {
  final ids = [
    'c1',
    'c2',
    'g1',
    'g2',
    's',
  ].where((id) => byKey('conversation-$id').evaluate().isNotEmpty).toList();
  ids.sort(
    (a, b) => t
        .getTopLeft(byKey('conversation-$a'))
        .dy
        .compareTo(t.getTopLeft(byKey('conversation-$b')).dy),
  );
  return ids;
}

/// Real fonts, so widths (and overflow) are measured as on a phone, not with
/// the test font's one-em-square glyphs: Roboto (Android's system font, which
/// the app draws with by default; the copy shipped in the Flutter SDK) and
/// Manrope (the app's own).
Future<void> loadAppFonts() async {
  final manrope = FontLoader('Manrope');
  for (final w in [400, 500, 600, 700, 800]) {
    manrope.addFont(
      File('assets/fonts/Manrope-$w.ttf')
          .readAsBytes()
          .then(ByteData.sublistView),
    );
  }
  await manrope.load();
  final root = Platform.environment['FLUTTER_ROOT']!;
  final roboto = FontLoader('Roboto');
  final dir = Directory(
    '$root/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/Roboto',
  );
  for (final f in dir.listSync().whereType<File>()) {
    if (f.path.endsWith('.ttf')) {
      roboto.addFont(f.readAsBytes().then(ByteData.sublistView));
    }
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      File('$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
          .readAsBytes()
          .then(ByteData.sublistView),
    );
  await icons.load();
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('1. selection toggles and count', (t) async {
    await pumpList(t);
    await select(t, ['c1']);
    expect(byKey('selected-check'), findsOneWidget);
    expect(count(t), '1');
    await t.tap(byKey('conversation-c2'));
    await t.pumpAndSettle();
    expect(count(t), '2');
    await t.tap(byKey('conversation-c2'));
    await t.pumpAndSettle();
    expect(count(t), '1');
    await t.tap(byKey('conversation-c1'));
    await t.pumpAndSettle();
    expect(byKey('selection-count'), findsNothing);
  });

  testWidgets('2. back and pop route clears selection', (t) async {
    await pumpList(t);
    await select(t, ['c1']);
    await t.tap(byKey('selection-back'));
    await t.pumpAndSettle();
    expect(byKey('selection-count'), findsNothing);
    await select(t, ['c1']);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    expect(byKey('selection-count'), findsNothing);
    expect(byKey('conversation-c1'), findsOneWidget);
  });

  testWidgets('3. delete is hidden while the system chat is selected', (
    t,
  ) async {
    await pumpList(t);
    await select(t, ['s']);
    expect(count(t), '1');
    expect(byKey('selection-delete'), findsNothing);
    await t.tap(byKey('conversation-s'));
    await t.pumpAndSettle();
    await select(t, ['c1']);
    expect(byKey('selection-delete'), findsOneWidget);
    await t.tap(byKey('conversation-s'));
    await t.pumpAndSettle();
    expect(count(t), '2');
    expect(byKey('selection-delete'), findsNothing);
  });

  testWidgets('4. Dialog B contents and cancel', (t) async {
    await pumpList(t);
    await openDelete(t, ['c1']);
    expect(find.text('Delete Chat'), findsWidgets);
    expect(boldShown(t, 'Bob Stone'), isTrue);
    expect(
      rich('Are you sure you want to delete the chat with Bob Stone?'),
      findsOneWidget,
    );
    expect(find.text('Also delete for Bob'), findsOneWidget);
    expect(byKey('delete-chat-check'), findsOneWidget);
    await t.tap(byKey('delete-chat-cancel'));
    await t.pumpAndSettle();
    expect(byKey('delete-chat-ok'), findsNothing);
    expect(count(t), '1');
  });

  testWidgets('5. B OK unticked', (t) async {
    final w = await pumpList(t);
    await openDelete(t, ['c1']);
    await confirm(t);
    expect(byKey('conversation-c1'), findsNothing);
    expect(byKey('selection-count'), findsNothing);
    expect(byKey('chat-undo-bar'), findsOneWidget);
    expect(find.text('Chat deleted'), findsOneWidget);
    expect(w.del.calls.isEmpty, isTrue);
    await runOut(t);
    expect(w.del.calls, ['hide:c1']);
    expect(byKey('conversation-c1'), findsNothing);
    expect(byKey('chat-undo-bar'), findsNothing);
  });

  testWidgets('6. B OK ticked', (t) async {
    final w = await pumpList(t);
    await openDelete(t, ['c1']);
    await confirm(t, tick: true);
    await runOut(t);
    expect(w.del.calls, ['deleteDirect:c1']);
  });

  testWidgets('7. Dialog A users', (t) async {
    await pumpList(t);
    await openDelete(t, ['c1', 'c2']);
    expect(find.text('Delete 2 chats'), findsOneWidget);
    expect(
      rich('Are you sure you want to delete selected chats?'),
      findsOneWidget,
    );
    expect(find.text('Delete for both sides where possible'), findsOneWidget);
    await confirm(t);
    expect(byKey('conversation-c1'), findsNothing);
    expect(byKey('conversation-c2'), findsNothing);
    expect(find.text('Chats deleted.'), findsOneWidget);
  });

  testWidgets('8. Dialog A groups only', (t) async {
    await pumpList(t);
    await openDelete(t, ['g1', 'g2']);
    expect(find.text('Delete 2 chats'), findsOneWidget);
    expect(byKey('delete-chat-check'), findsNothing);
  });

  testWidgets('9. Dialog C leave group', (t) async {
    await pumpList(t);
    await openDelete(t, ['g1']);
    expect(find.text('Leave Group'), findsWidgets);
    expect(
      rich('Are you sure you want to delete and leave the group Trip?'),
      findsOneWidget,
    );
    expect(boldShown(t, 'Trip'), isTrue);
    expect(byKey('delete-chat-check'), findsNothing);
    await confirm(t);
    expect(find.text('You left the group.'), findsOneWidget);
  });

  testWidgets('10. Dialog D ticked', (t) async {
    final w = await pumpList(t);
    await openDelete(t, ['g2']);
    expect(find.text('Leave Group'), findsWidgets);
    expect(find.text('Delete the group for all members'), findsOneWidget);
    await confirm(t, tick: true);
    expect(find.text('Group deleted.'), findsOneWidget);
    await runOut(t);
    expect(w.groups.calls, contains('delete:g2'));
  });

  testWidgets('11. Dialog D unticked', (t) async {
    await pumpList(t);
    await openDelete(t, ['g2']);
    await confirm(t);
    expect(find.text('You left the group.'), findsOneWidget);
  });

  testWidgets('12. Undo restores order', (t) async {
    final w = await pumpList(t);
    await openDelete(t, ['c2']);
    await confirm(t);
    expect(order(t), ['c1', 'g1', 'g2', 's']);
    await t.tap(byKey('chat-undo-button'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(order(t), ['c1', 'c2', 'g1', 'g2', 's']);
    expect(byKey('chat-undo-bar'), findsNothing);
    await runOut(t);
    expect(w.del.calls, isEmpty);
    // 'subscribe' is the live listener, not a server write.
    expect(w.groups.calls.where((c) => c != 'subscribe'), isEmpty);
    expect(w.chat.groupWrites, isEmpty);
  });

  testWidgets('13. Countdown timer', (t) async {
    await pumpList(t);
    await openDelete(t, ['c1']);
    await confirm(t);
    expect(
      find.descendant(of: byKey('chat-undo-bar'), matching: find.text('5')),
      findsOneWidget,
    );
    for (var n in [4, 3, 2, 1]) {
      await t.pump(const Duration(seconds: 1));
      expect(
        find.descendant(of: byKey('chat-undo-bar'), matching: find.text('$n')),
        findsOneWidget,
      );
    }
    await t.pump(const Duration(seconds: 2));
    await t.pumpAndSettle();
    expect(byKey('chat-undo-bar'), findsNothing);
  });

  testWidgets('14. Refusal shows notice', (t) async {
    final w = await pumpList(t);
    w.del.hideResult = const Err(NetworkFailure('offline'));
    await openDelete(t, ['c1']);
    await confirm(t);
    // The 5 s window, then the refused call (40 ms) and the reload.
    await t.pump(const Duration(seconds: 5));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(w.del.calls, ['hide:c1']);
    expect(ui.notice, findsOneWidget);
    expect(byKey('conversation-c1'), findsOneWidget);
    await ui.drainNotice(t);
  });

  testWidgets('15. Turkish B dialog', (t) async {
    await pumpList(t, tr: true);
    await openDelete(t, ['c1']);
    expect(find.text('Sohbeti Sil'), findsWidgets);
    expect(rich('ile olan sohbet kalıcı olarak silinsin mi?'), findsOneWidget);
    expect(boldShown(t, 'Bob Stone'), isTrue);
    expect(find.text('Bob için de sil'), findsOneWidget);
    expect(find.text('İptal et'), findsOneWidget);
    await confirm(t);
    expect(find.text('Sohbet silindi.'), findsOneWidget);
    expect(find.text('Geri Al'), findsOneWidget);
  });

  testWidgets('16. Turkish A + D flow', (t) async {
    await pumpList(t, tr: true);
    await openDelete(t, ['c1', 'c2']);
    expect(find.text('2 sohbet sil'), findsOneWidget);
    expect(find.text('Mümkünse her iki taraftan da silin'), findsOneWidget);
    await t.tap(byKey('delete-chat-cancel'));
    await t.pumpAndSettle();
    await t.tap(byKey('selection-back'));
    await t.pumpAndSettle();
    await openDelete(t, ['g2']);
    expect(find.text('Gruptan Ayrıl'), findsWidgets);
    expect(find.text('Grubu tüm üyeler için sil'), findsOneWidget);
    await confirm(t, tick: true);
    expect(find.text('Grup silindi'), findsOneWidget);
  });

  testWidgets('17. Turkish 360 wide layout', (t) async {
    t.view.physicalSize = const Size(1080, 1920);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await pumpList(t, tr: true);
    await select(t, ['c1', 'g1']);
    expect(t.takeException(), isNull);
    await t.tap(byKey('selection-more'));
    await t.pumpAndSettle();
    expect(byKey('selection-archive'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.binding.handlePopRoute();
    await t.pumpAndSettle();
    await t.tap(byKey('selection-back'));
    await t.pumpAndSettle();
    await openDelete(t, ['c1', 'c2']);
    expect(t.takeException(), isNull);
    await t.tap(byKey('delete-chat-cancel'));
    await t.pumpAndSettle();
    await t.tap(byKey('selection-back'));
    await t.pumpAndSettle();
    await openDelete(t, ['c1']);
    expect(t.takeException(), isNull);
    await t.tap(byKey('delete-chat-cancel'));
    await t.pumpAndSettle();
    await t.tap(byKey('selection-back'));
    await t.pumpAndSettle();
    await openDelete(t, ['g2']);
    expect(t.takeException(), isNull);
    await confirm(t, tick: true);
    expect(t.takeException(), isNull);
    expect(byKey('chat-undo-bar'), findsOneWidget);
  });
}
