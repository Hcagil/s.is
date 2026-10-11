// Stickers (10a) in a real MessageScreen opened as production opens it
// (openChat), written from the contract: the panel and its tabs, tap to
// send, long-press and tap to save, the starter page, the album page menu,
// shared album cards keyed by message id, a sticker drawn without a bubble
// box (also when it comes from history), and back closing only the panel.
// Fakes only at the repository boundary (StickerRepoFake, ChatFake).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/sticker.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/starter_album_page.dart';
import 'package:sis/features/chat/presentation/sticker_album_page.dart';

import '../../support/chat_launcher.dart';
import '../../support/fakes.dart';
import '../../support/sticker_fakes.dart';

Finder k(String key) => find.byKey(ValueKey(key));

final starter1 = starterStickerIds.first;

Message stickerMsg(String id, String stickerId, {String from = 'u2'}) =>
    Message(
      id: id,
      conversationId: 'c1',
      senderId: from,
      body: '',
      createdAt: DateTime.now(),
      stickerId: stickerId,
    );

Message albumCardMsg(String id, String albumId, {String from = 'u2'}) =>
    Message(
      id: id,
      conversationId: 'c1',
      senderId: from,
      body: 'Cats',
      createdAt: DateTime.now(),
      albumCard: true,
      albumId: albumId,
    );

class Env {
  Env(this.repo, this.recent);
  final StickerRepoFake repo;
  final RecentStickerStoreFake recent;
}

/// Opens chat c1 with [messages] in its history and the sticker fakes.
Future<Env> open(
  WidgetTester t, {
  List<Message>? messages,
  StickerRepoFake? repo,
  List<String>? recent,
}) async {
  final r =
      repo ??
      StickerRepoFake(images: {'s1': pngBytes, 's2': pngBytes, 's3': pngBytes});
  final rec = RecentStickerStoreFake(recent ?? []);
  final c = await openChat(
    t,
    messages: messages ?? [chatMessage('m0')],
    overrides: [
      stickerRepositoryProvider.overrideWithValue(r),
      recentStickerStoreProvider.overrideWithValue(rec),
    ],
  );
  // as the app root (SisApp) keeps it
  c.listen(recentStickerOwnerProvider, (_, _) {});
  await t.pumpAndSettle();
  return Env(r, rec);
}

/// Lets a notice (2 s) run out so no timer is left pending.
Future<void> noticesGone(WidgetTester t) async {
  await t.pump(const Duration(seconds: 3));
  await t.pumpAndSettle();
}

Future<void> openPanel(WidgetTester t) async {
  await t.tap(k('composer-stickers'));
  await t.pumpAndSettle();
  expect(k('sticker-panel'), findsOneWidget);
}

/// Brings tab [i] into view (the tab row scrolls) and selects it.
Future<void> tab(WidgetTester t, int i) async {
  final y = t.getCenter(k('sticker-tab-0').hitTestable()).dy;
  for (var n = 0; n < 10 && k('sticker-tab-$i').evaluate().isEmpty; n++) {
    await t.dragFrom(Offset(200, y), const Offset(-120, 0));
    await t.pumpAndSettle();
  }
  await t.ensureVisible(k('sticker-tab-$i'));
  await t.pumpAndSettle();
  await t.tap(k('sticker-tab-$i'));
  await t.pumpAndSettle();
}

/// The `panel-sticker-<id>` ids now built, left to right, top to bottom.
List<String> panelStickers(WidgetTester t) {
  final found = find.byWidgetPredicate(
    (w) =>
        w.key is ValueKey<String> &&
        (w.key as ValueKey<String>).value.startsWith('panel-sticker-'),
  );
  final list = found.evaluate().toList()
    ..sort((a, b) {
      final ra = t.getRect(find.byWidget(a.widget));
      final rb = t.getRect(find.byWidget(b.widget));
      final dy = ra.top.compareTo(rb.top);
      return dy != 0 ? dy : ra.left.compareTo(rb.left);
    });
  return [
    for (final e in list)
      (e.widget.key as ValueKey<String>).value.substring(
        'panel-sticker-'.length,
      ),
  ];
}

/// Painted boxes (a BoxDecoration with a visible colour) inside message
/// [id]'s row that enclose [inner]: a bubble.
List<Rect> boxesAround(WidgetTester t, String id, Finder inner) {
  final r = t.getRect(inner);
  final boxes = <Rect>[];
  for (final e
      in find
          .descendant(of: k('message-$id'), matching: find.byType(DecoratedBox))
          .evaluate()) {
    final d = (e.widget as DecoratedBox).decoration;
    if (d is! BoxDecoration) continue;
    final c = d.color;
    if (c == null || c.a == 0) continue;
    final box = t.getRect(find.byWidget(e.widget));
    if (box.contains(r.topLeft + const Offset(1, 1)) &&
        box.contains(r.bottomRight - const Offset(1, 1))) {
      boxes.add(box);
    }
  }
  return boxes;
}

void main() {
  group('panel', () {
    testWidgets('the sticker button opens the panel with its five tabs in '
        'order: Recent, Favourites, SIS starter, My stickers, + New', (
      t,
    ) async {
      await open(t);
      expect(k('sticker-panel'), findsNothing);
      await openPanel(t);
      final labels = <String>[];
      for (var i = 0; i < 5; i++) {
        await t.ensureVisible(k('sticker-tab-$i'));
        await t.pumpAndSettle();
        final f = k('sticker-tab-$i');
        labels.add(
          t
              .widgetList<Text>(
                find.descendant(of: f, matching: find.byType(Text)),
              )
              .map((x) => x.data)
              .join(),
        );
      }
      expect(labels, [
        'Recent',
        'Favourites',
        'SIS starter',
        'My stickers',
        '+ New',
      ]);
    });

    testWidgets('Recent lists the recent store newest first', (t) async {
      await open(t, recent: ['s2', 's1']);
      await openPanel(t);
      await tab(t, 0);
      expect(panelStickers(t), ['s2', 's1']);
    });

    testWidgets('Favourites lists the repository favourites newest first', (
      t,
    ) async {
      final repo = StickerRepoFake(images: {'s1': pngBytes, 's3': pngBytes});
      repo.favs.addAll(['s3', 's1']);
      await open(t, repo: repo);
      await openPanel(t);
      await tab(t, 1);
      expect(panelStickers(t), ['s3', 's1']);
    });

    testWidgets('the starter tab shows bundled starter stickers only', (
      t,
    ) async {
      await open(t);
      await openPanel(t);
      await tab(t, 2);
      final ids = panelStickers(t);
      expect(ids, isNotEmpty);
      expect(ids.every(isStarterSticker), isTrue, reason: '$ids');
      expect(ids.first, starter1);
    });

    testWidgets('My stickers lists my albums oldest first and a New row', (
      t,
    ) async {
      final repo = StickerRepoFake();
      repo.albumList.addAll(const [
        StickerAlbum(id: 'a1', name: 'First'),
        StickerAlbum(id: 'a2', name: 'Second'),
      ]);
      await open(t, repo: repo);
      await openPanel(t);
      await tab(t, 3);
      expect(k('sticker-albums-list'), findsOneWidget);
      expect(k('panel-album-new'), findsOneWidget);
      expect(
        t.getRect(k('panel-album-a1')).top,
        lessThan(t.getRect(k('panel-album-a2')).top),
      );
    });

    testWidgets('+ New opens the create page', (t) async {
      await open(t);
      await openPanel(t);
      await tab(t, 4);
      expect(k('sticker-create-page'), findsOneWidget);
    });

    testWidgets('tapping a sticker sends it at once, shows it in the chat '
        'and puts it first in Recent', (t) async {
      final e = await open(t, recent: ['s2', 's1']);
      await openPanel(t);
      await tab(t, 0);
      await t.tap(k('panel-sticker-s1'));
      await t.pump();
      expect(e.repo.sends, hasLength(1));
      final s = e.repo.sends.single;
      expect(s.conversationId, 'c1');
      expect(s.stickerId, 's1');
      expect(s.albumId, isNull);
      e.repo.ok(0);
      await t.pumpAndSettle();
      expect(k('sticker-${s.messageId}'), findsOneWidget);
      expect(e.recent.ids.first, 's1');
    });
  });

  group('in the chat', () {
    testWidgets('a sticker from history is drawn as a sticker of about 160 '
        'px with no bubble box; a text message keeps its box', (t) async {
      await open(t, messages: [chatMessage('m0'), stickerMsg('m1', 's1')]);
      final st = k('sticker-m1');
      expect(st, findsOneWidget);
      final r = t.getRect(st);
      expect(r.width, inInclusiveRange(140, 180));
      expect(boxesAround(t, 'm1', k('sticker-image-s1')), isEmpty);
      // control: the same probe finds the bubble of a text message
      expect(boxesAround(t, 'm0', k('body-m0')), isNotEmpty);
    });

    testWidgets('in a group the sender name sits above the sticker', (t) async {
      await open(t, messages: [stickerMsg('m1', 's1')]);
      expect(k('sender-m1'), findsOneWidget);
      expect(
        t.getRect(k('sender-m1')).bottom,
        lessThanOrEqualTo(t.getRect(k('sticker-m1')).top + 1),
      );
    });

    testWidgets('long-press a received sticker: Add to favourites saves it', (
      t,
    ) async {
      final e = await open(t, messages: [stickerMsg('m1', 's1')]);
      await t.longPress(k('sticker-m1'));
      await t.pumpAndSettle();
      await t.tap(find.text('Add to favourites').last);
      await t.pumpAndSettle();
      expect(e.repo.calls, contains('addFavourite s1'));
      expect(e.repo.favs, ['s1']);
      await noticesGone(t);
    });

    testWidgets('long-press a received sticker: Add to album puts it in the '
        'picked album', (t) async {
      final repo = StickerRepoFake(images: {'s1': pngBytes});
      repo.albumList.add(const StickerAlbum(id: 'a1', name: 'Mine'));
      await open(t, repo: repo, messages: [stickerMsg('m1', 's1')]);
      await t.longPress(k('sticker-m1'));
      await t.pumpAndSettle();
      await t.tap(find.text('Add to album').last);
      await t.pumpAndSettle();
      expect(k('album-picker'), findsOneWidget);
      await t.tap(
        find.descendant(of: k('album-picker'), matching: find.text('Mine')),
      );
      await t.pumpAndSettle();
      expect(repo.calls, contains('addToAlbum a1 s1'));
      expect(repo.albumList.single.stickerIds, ['s1']);
      await noticesGone(t);
    });

    testWidgets('long-press my own sticker offers no save actions', (t) async {
      await open(t, messages: [stickerMsg('m1', 's1', from: 'u1')]);
      await t.longPress(k('sticker-m1'));
      await t.pumpAndSettle();
      expect(find.text('Add to favourites'), findsNothing);
      expect(find.text('Add to album'), findsNothing);
    });

    testWidgets('tap a received sticker: the save card adds it to favourites '
        'and says so', (t) async {
      final e = await open(t, messages: [stickerMsg('m1', 's1')]);
      await t.tap(k('sticker-m1'));
      await t.pumpAndSettle();
      expect(k('sticker-save-menu'), findsOneWidget);
      expect(k('menu-sticker-album'), findsOneWidget);
      await t.tap(k('menu-sticker-favourite'));
      await t.pumpAndSettle();
      expect(e.repo.calls, contains('addFavourite s1'));
      expect(find.text('Added to favourites.'), findsOneWidget);
      await noticesGone(t);
    });

    testWidgets('save card at the favourites limit shows the limit text', (
      t,
    ) async {
      final e = await open(t, messages: [stickerMsg('m1', 's1')]);
      e.repo.failNext = const StickerLimitFailure('STKF1');
      await t.tap(k('sticker-m1'));
      await t.pumpAndSettle();
      await t.tap(k('menu-sticker-favourite'));
      await t.pumpAndSettle();
      expect(find.text('Added to favourites.'), findsNothing);
      expect(find.text('You can keep up to 200 favourites.'), findsOneWidget);
      await noticesGone(t);
    });

    testWidgets('save card: the album action opens the album picker with my '
        'albums', (t) async {
      final repo = StickerRepoFake(images: {'s1': pngBytes});
      repo.albumList.add(const StickerAlbum(id: 'a1', name: 'Mine'));
      await open(t, repo: repo, messages: [stickerMsg('m1', 's1')]);
      await t.tap(k('sticker-m1'));
      await t.pumpAndSettle();
      await t.tap(k('menu-sticker-album'));
      await t.pumpAndSettle();
      expect(k('album-picker'), findsOneWidget);
      expect(
        find.descendant(of: k('album-picker'), matching: find.text('Mine')),
        findsOneWidget,
        reason: 'the picker lists my albums',
      );
    });

    testWidgets('tap a starter sticker: the starter page opens; tapping one '
        'sends it and closes the page', (t) async {
      final e = await open(t, messages: [stickerMsg('m1', starter1)]);
      await t.tap(k('sticker-m1'));
      await settle(t);
      expect(find.byType(StarterAlbumPage), findsOneWidget);
      expect(k('sticker-save-menu'), findsNothing);
      final pick = starterStickerIds.last;
      await t.ensureVisible(k('starter-sticker-$pick'));
      await t.pumpAndSettle();
      await t.tap(k('starter-sticker-$pick'));
      await t.pump();
      expect(e.repo.sends.single.stickerId, pick);
      expect(e.repo.sends.single.conversationId, 'c1');
      await settle(t);
      expect(find.byType(StarterAlbumPage), findsNothing);
      expect(find.byType(MessageScreen), findsOneWidget);
    });
  });

  group('album page menu', () {
    // Opened straight from the chat's launcher: the panel's My stickers tab
    // has its own failing test (see 'My stickers lists ...').
    Future<StickerRepoFake> openAlbum(WidgetTester t) async {
      final repo = StickerRepoFake(images: {'s1': pngBytes});
      repo.albumList.add(
        const StickerAlbum(id: 'a1', name: 'Mine', stickerIds: ['s1']),
      );
      await pumpLauncher(
        t,
        (context, ref) => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) =>
                const StickerAlbumPage(albumId: 'a1', conversationId: 'c1'),
          ),
        ),
        overrides: [
          stickerRepositoryProvider.overrideWithValue(repo),
          recentStickerStoreProvider.overrideWithValue(
            RecentStickerStoreFake(),
          ),
        ],
      );
      expect(k('sticker-album-page'), findsOneWidget);
      expect(k('album-sticker-s1'), findsOneWidget);
      await t.tap(k('sticker-album-menu'));
      await t.pumpAndSettle();
      return repo;
    }

    testWidgets('Share album sends the album card to this chat', (t) async {
      final repo = await openAlbum(t);
      await t.tap(find.text('Share album'));
      await t.pump();
      expect(repo.sends, hasLength(1));
      expect(repo.sends.single.albumId, 'a1');
      expect(repo.sends.single.conversationId, 'c1');
      repo.ok(0);
      await t.pumpAndSettle();
      await noticesGone(t);
    });

    testWidgets('Rename asks for a name and renames', (t) async {
      final repo = await openAlbum(t);
      await t.tap(find.text('Rename'));
      await t.pumpAndSettle();
      expect(k('album-name-card'), findsOneWidget);
      await t.enterText(k('album-name-field'), 'Cats');
      await t.tap(k('album-name-ok'));
      await t.pumpAndSettle();
      expect(repo.calls, contains('renameAlbum a1 Cats'));
      await noticesGone(t);
    });

    testWidgets('Delete album asks first, then deletes', (t) async {
      final repo = await openAlbum(t);
      await t.tap(find.text('Delete album'));
      await t.pumpAndSettle();
      expect(find.text('Delete this album?'), findsOneWidget);
      expect(repo.calls.where((c) => c.startsWith('deleteAlbum')), isEmpty);
      await t.tap(find.text('Delete'));
      await t.pumpAndSettle();
      expect(repo.calls, contains('deleteAlbum a1'));
      expect(repo.albumList, isEmpty);
      await noticesGone(t);
    });
  });

  group('shared album card', () {
    testWidgets('two cards of one album: each button is keyed by its message '
        'and acts on the album', (t) async {
      final repo = StickerRepoFake(
        images: {'s1': pngBytes},
        shared: {
          'alb': ['s1'],
        },
      );
      await open(
        t,
        repo: repo,
        messages: [albumCardMsg('m3', 'alb'), albumCardMsg('m4', 'alb')],
      );
      for (final id in ['m3', 'm4']) {
        expect(k('album-card-$id'), findsOneWidget);
        expect(k('album-add-$id'), findsOneWidget);
        expect(k('album-fav-$id'), findsOneWidget);
      }
      await t.tap(k('album-add-m4'));
      await t.pumpAndSettle();
      expect(repo.calls, contains('addSharedAlbum alb'));
      expect(repo.albumList, hasLength(1));
      await t.tap(k('album-fav-m3'));
      await t.pumpAndSettle();
      expect(repo.calls, contains('addSharedAlbumToFavourites alb'));
      expect(repo.favs, ['s1']);
      await noticesGone(t);
    });

    testWidgets('tapping the card previews its stickers', (t) async {
      final repo = StickerRepoFake(
        images: {'s1': pngBytes},
        shared: {
          'alb': ['s1'],
        },
      );
      await open(t, repo: repo, messages: [albumCardMsg('m3', 'alb')]);
      await t.tap(find.text('Cats'));
      await settle(t);
      expect(k('album-preview-page'), findsOneWidget);
      expect(k('album-preview-add'), findsOneWidget);
      expect(k('album-preview-fav'), findsOneWidget);
    });
  });

  // Contract: "Tap a deleted sticker or one in a system chat -> old 'Seen
  // by' toggle": no save card, no starter page; the plain tap rules apply
  // (a tap opens the message, a second closes it; a system chat has no
  // tap extras).
  group('tap falls back to the plain toggle', () {
    Message deleted(String id, String stickerId) => Message(
      id: id,
      conversationId: 'c1',
      senderId: 'u2',
      body: '',
      createdAt: DateTime.now(),
      stickerId: stickerId,
      deletion: MessageDeletion.placeholder,
    );

    Future<ProviderContainer> openIn(
      WidgetTester t,
      List<Message> messages, {
      bool system = false,
    }) async {
      final chat = ChatFake(self: me.userId)
        ..history['c1'] = messages
        ..roster['c1'] = [me, bob]
        ..membersResult = const Ok([bob])
        ..conversationsResult = Ok([
          Conversation(id: 'c1', title: 'Bob', isSystem: system),
        ]);
      final c = await pumpLauncher(
        t,
        (context, ref) => openConversation(context, ref, 'c1', title: 'Bob'),
        chat: chat,
        overrides: [
          stickerRepositoryProvider.overrideWithValue(
            StickerRepoFake(images: {'s1': pngBytes}),
          ),
          recentStickerStoreProvider.overrideWithValue(
            RecentStickerStoreFake([]),
          ),
        ],
      );
      await t.pumpAndSettle();
      return c;
    }

    testWidgets('a deleted sticker (starter or not) toggles the message '
        'open, with no save card and no starter page', (t) async {
      final c = await openIn(t, [
        deleted('d1', 's1'),
        deleted('d2', starter1),
        stickerMsg('m1', 's1'),
      ]);
      for (final id in ['d1', 'd2']) {
        await t.tap(k('message-$id'));
        await t.pumpAndSettle();
        expect(k('sticker-save-menu'), findsNothing, reason: id);
        expect(find.byType(StarterAlbumPage), findsNothing, reason: id);
        expect(c.read(tappedMessageProvider), id, reason: '$id opened');
        await t.tap(k('message-$id'));
        await t.pumpAndSettle();
        expect(c.read(tappedMessageProvider), isNull, reason: '$id closed');
      }
      // control: the same harness does open the save card for a live one
      await t.tap(k('sticker-m1'));
      await t.pumpAndSettle();
      expect(k('sticker-save-menu'), findsOneWidget);
    });

    testWidgets('a sticker in a system chat (starter or not) opens nothing', (
      t,
    ) async {
      final c = await openIn(t, [
        stickerMsg('m1', 's1'),
        stickerMsg('m2', starter1),
      ], system: true);
      expect(
        k('composer-system'),
        findsOneWidget,
        reason: 'precondition: the screen knows it is the system chat',
      );
      // The system chat draws its messages as its own cards; tap whatever
      // stands for each message (a card or a message row).
      final rows = find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            RegExp(r'^(message-m\d|whats-new-card-)')
                .hasMatch((w.key! as ValueKey<String>).value),
      );
      expect(rows, findsNWidgets(2), reason: 'precondition: both shown');
      for (var i = 0; i < 2; i++) {
        await t.tap(rows.at(i));
        await t.pumpAndSettle();
        expect(k('sticker-save-menu'), findsNothing, reason: 'card $i');
        expect(find.byType(StarterAlbumPage), findsNothing, reason: 'card $i');
        expect(c.read(tappedMessageProvider), isNull, reason: 'card $i');
      }
    });
  });

  group('back', () {
    testWidgets('back with the panel open closes only the panel; back again '
        'leaves the chat', (t) async {
      await open(t);
      await openPanel(t);
      await osBack(t);
      expect(k('sticker-panel'), findsNothing);
      expect(find.byType(MessageScreen), findsOneWidget);
      await osBack(t);
      expect(find.byType(MessageScreen), findsNothing);
    });
  });
}
