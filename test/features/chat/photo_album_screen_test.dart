// Photo albums on the chat screen, from the contract (feat/photo-albums):
//
// - photos of one sender sharing a photo group draw as one album: 2 to 4
//   photos as a grid of that many tiles; 5 to 10 as 4 tiles, the last one
//   showing "+N" for the photos not drawn;
// - a lone photo with a group, or photos of different groups, stay plain;
// - in the photo viewer an album photo's menu deletes and forwards THAT
//   photo only; its delete-for-everyone row reads "Delete this photo", while
//   "Delete for me" keeps its label.
//
// Wired as the app mounts it: MessageScreen over the controllers, with the
// shared server-like ChatFake behind the repository.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/theme.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/chat/presentation/photo_viewer.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/l10n/app_localizations.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Message photo(String id, {String? group, int minute = 0, String from = 'u1'}) =>
    Message(
      id: id,
      conversationId: 'c1',
      senderId: from,
      body: '',
      createdAt: DateTime.now().subtract(Duration(minutes: 60 - minute)),
      attachmentPath: 'c1/$id.png',
      photoGroup: group,
    );

/// [n] photos of one album, a second apart.
List<Message> album(int n, {String group = 'g1'}) => [
  for (var i = 1; i <= n; i++) photo('p$i', group: group),
];

Future<ChatFake> pump(WidgetTester tester, List<Message> messages) async {
  final chat =
      ChatFake(self: me.userId, latency: const Duration(milliseconds: 5))
        ..history['c1'] = [...messages]
        ..conversationsResult = const Ok([
          Conversation(id: 'c1', title: 'Bob'),
          Conversation(id: 'c2', title: 'Work'),
        ]);
  for (final m in messages) {
    if (m.attachmentPath case final path?) chat.store(path);
  }
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        linkOpenerProvider.overrideWithValue(LinkOpenerFake()),
        galleryProvider.overrideWithValue(GalleryFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: sisTheme(Brightness.light),
        home: const MessageScreen(title: 'Bob'),
      ),
    ),
  );
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  await settleImages(tester);
  await tester.pumpAndSettle();
  return chat;
}

Finder albumOf(String firstId) => find.byKey(ValueKey('album-$firstId'));

void main() {
  Finder tiles(String firstId) =>
      find.descendant(of: albumOf(firstId), matching: find.byType(RawImage));

  group('the album grid', () {
    for (final n in [2, 3, 4]) {
      testWidgets('$n photos: one album of $n tiles, no "+"', (tester) async {
        await pump(tester, album(n));

        expect(albumOf('p1'), findsOneWidget);
        expect(tiles('p1'), findsNWidgets(n));
        expect(
          find.descendant(
            of: albumOf('p1'),
            matching: find.textContaining('+'),
          ),
          findsNothing,
        );
        for (var i = 2; i <= n; i++) {
          expect(
            albumOf('p$i'),
            findsNothing,
            reason: 'p$i drew its own album',
          );
        }
      });
    }

    for (final n in [5, 7, 10]) {
      testWidgets('$n photos: 4 tiles, the last showing +${n - 4}', (
        tester,
      ) async {
        await pump(tester, album(n));

        expect(albumOf('p1'), findsOneWidget);
        expect(tiles('p1'), findsNWidgets(4));
        final more = find.descendant(
          of: albumOf('p1'),
          matching: find.text('+${n - 4}'),
        );
        expect(more, findsOneWidget);
        // on the last tile: the bottom-right one
        final last = tiles('p1')
            .evaluate()
            .map((e) => tester.getRect(find.byWidget(e.widget)))
            .reduce(
              (a, b) =>
                  a.bottom > b.bottom ||
                      (a.bottom == b.bottom && a.right > b.right)
                  ? a
                  : b,
            );
        expect(
          last.contains(tester.getCenter(more)),
          isTrue,
          reason: '+N is not on the last tile',
        );
      });
    }

    testWidgets('a lone photo with a group stays a plain photo', (
      tester,
    ) async {
      await pump(tester, [photo('p1', group: 'g1')]);
      expect(albumOf('p1'), findsNothing);
      expect(
        find.byKey(const ValueKey('attachment-c1/p1.png')),
        findsOneWidget,
      );
    });

    testWidgets('photos of different groups are not one album', (tester) async {
      await pump(tester, [
        photo('p1', group: 'g1'),
        photo('p2', group: 'g2', minute: 1),
      ]);
      expect(albumOf('p1'), findsNothing);
      expect(albumOf('p2'), findsNothing);
    });

    testWidgets('one group from two senders is not one album', (tester) async {
      await pump(tester, [
        photo('p1', group: 'g1'),
        photo('p2', group: 'g1', minute: 1, from: 'u2'),
      ]);
      expect(albumOf('p1'), findsNothing);
      expect(albumOf('p2'), findsNothing);
    });

    testWidgets('photos without a group are not an album', (tester) async {
      await pump(tester, [photo('p1'), photo('p2', minute: 1)]);
      expect(albumOf('p1'), findsNothing);
    });
  });

  group('the viewer menu on an album photo', () {
    /// Opens the viewer on the album's second tile; the photo it shows.
    Future<String> openSecond(WidgetTester tester) async {
      await tester.tap(tiles('p1').at(1));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoViewer), findsOneWidget);
      await settleImages(tester);
      await tester.pumpAndSettle();
      final screen =
          Offset.zero & tester.view.physicalSize / tester.view.devicePixelRatio;
      final onScreen = [
        for (final e
            in find
                .byWidgetPredicate(
                  (w) =>
                      w.key is ValueKey<String> &&
                      (w.key! as ValueKey<String>).value.startsWith(
                        'viewer-image-',
                      ),
                )
                .evaluate())
          if (screen.contains(tester.getCenter(find.byWidget(e.widget))))
            e.widget.key! as ValueKey<String>,
      ];
      expect(onScreen, hasLength(1), reason: 'which photo is shown? $onScreen');
      final key = onScreen.single;
      final path = key.value.substring('viewer-image-'.length);
      await tester.tap(find.byKey(const ValueKey('viewer-menu')));
      await tester.pumpAndSettle();
      final id = path.split('/').last.split('.').first;
      expect(id, 'p2', reason: 'the viewer did not open on the tapped tile');
      return id;
    }

    testWidgets('delete for everyone reads "Delete this photo"; "Delete for '
        'me" keeps its label', (tester) async {
      await pump(tester, album(3));
      await openSecond(tester);

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('menu-delete-for-everyone')),
          matching: find.text('Delete this photo'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('menu-delete-for-me')),
          matching: find.text('Delete for me'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a plain photo keeps "Delete for everyone"', (tester) async {
      await pump(tester, [photo('p1')]);
      await tester.tap(find.byKey(const ValueKey('attachment-c1/p1.png')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('viewer-menu')));
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const ValueKey('menu-delete-for-everyone')),
          matching: find.text('Delete for everyone'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('"Delete this photo" deletes that photo only', (tester) async {
      final chat = await pump(tester, album(3));
      final id = await openSecond(tester);

      await tester.tap(find.byKey(const ValueKey('menu-delete-for-everyone')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('delete-confirm')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(chat.deleted, [id]);
    });

    testWidgets('forward sends that photo only, as one plain forward', (
      tester,
    ) async {
      final chat = await pump(tester, album(3));
      final id = await openSecond(tester);

      await tester.tap(find.byKey(const ValueKey('menu-forward')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('forward-c2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('forward-send')));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(chat.forwarded, hasLength(1));
      expect(chat.forwarded.single.messageId, id);
      expect(chat.forwarded.single.conversationIds, ['c2']);
      await tester.pump(const Duration(seconds: 10)); // the snackbar's timer
      await tester.pumpAndSettle();
    });
  });
}
