// The attachment sheet, written from its contract in
// lib/features/chat/domain/gallery.dart and
// lib/features/chat/presentation/attachment_sheet.dart: what a member sees
// at each access level (full, limited, denied, permanently denied), what
// tapping a photo, "Allow more", "Allow photos", "Open settings" or "Not
// now" actually does, and how the composer wires the sheet's outcome to
// MessagesController -- never how the sheet is built. Mounted through the
// real composer, exactly as production opens it: entry to the sheet is not
// a fixture, it's part of the contract.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/attach_flow.dart' hide key;
import '../../support/gallery_paging.dart';

import 'package:sis/l10n/app_localizations.dart';

import '../../support/video_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

GalleryPhoto photo(String id) => GalleryPhoto(id);

/// A distinct picture per [i], so a test can tell which photo was sent.
PickedImage shot(int i) => PickedImage(
  bytes: Uint8List.fromList([...photoPng, i]),
  contentType: 'image/png',
  extension: 'png',
);

Future<ProviderContainer> _scope(ChatFake chat, Gallery gallery) => settled(
  ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      galleryProvider.overrideWithValue(gallery),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  ),
);

Future<ProviderContainer> pump(
  WidgetTester tester,
  ChatFake chat,
  Gallery gallery,
) async {
  // A phone in portrait (411 x 891 dp, a common Android size), not the
  // test default of an 800 x 600 landscape window.
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final container = await _scope(chat, gallery);
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MessageScreen(title: 'Bob'),
      ),
    ),
  );
  await tester.pump();
  return container;
}

// 0.30.10: the paperclip opens the grid itself, no menu in between.
Future<void> openSheet(WidgetTester tester) => openGrid(tester);

String composerText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('composer-field')),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

/// The label on the access screen's main button.
Finder allowLabelled(String label) => find.descendant(
  of: find.byKey(const ValueKey('sheet-allow')),
  matching: find.text(label),
);

/// The sheet's old ways out to Android's own photo picker. None may exist:
/// SIS never hands the member to an Android-drawn picker.
void expectNoAndroidPicker() {
  expect(find.byKey(const ValueKey('sheet-system-picker')), findsNothing);
  expect(find.byKey(const ValueKey('sheet-select-more')), findsNothing);
  expect(find.text('All photos'), findsNothing);
}

/// SIS's own access screen, shown instead of the grid.
void expectAccessScreen() {
  expect(find.text('Send photos faster'), findsOneWidget);
  expect(
    find.byWidgetPredicate(
      (w) =>
          w is Text &&
          w.data != 'Send photos faster' &&
          (w.data ?? '').trim().split(' ').length >= 5,
    ),
    findsAtLeastNWidgets(1),
    reason: 'the screen explains itself in a sentence, not just a button',
  );
  expect(find.byKey(const ValueKey('sheet-not-now')), findsOneWidget);
  expect(find.byType(GridView), findsNothing);
}

void main() {
  group('full access', () {
    testWidgets('shows the phone\'s photos in a 3-wide grid', (tester) async {
      final gallery =
          GalleryFake(
              photos: [photo('p1'), photo('p2'), photo('p3'), photo('p4')],
            )
            ..thumbnails.addAll({
              'p1': photoPng,
              'p2': photoPng,
              'p3': photoPng,
              'p4': photoPng,
            });
      await pump(tester, ChatFake(), gallery);

      await openSheet(tester);

      expect(find.byKey(const ValueKey('sheet-photo-p1')), findsOneWidget);
      expect(find.byKey(const ValueKey('sheet-photo-p4')), findsOneWidget);
      final delegate =
          tester.widget<GridView>(find.byType(GridView)).gridDelegate
              as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 3);
      expect(gallery.accessRequests, 1);
      expect(find.byKey(const ValueKey('sheet-allow')), findsNothing);
      expect(find.byKey(const ValueKey('sheet-allow-more')), findsNothing);
      expectNoAndroidPicker();
    });

    testWidgets('with no photos says so plainly', (tester) async {
      await pump(tester, ChatFake(), GalleryFake());

      await openSheet(tester);

      expect(find.text('No photos yet'), findsOneWidget);
      expectNoAndroidPicker();
    });
  });

  group('limited access', () {
    testWidgets('shows only what was allowed, plus "Allow more"', (
      tester,
    ) async {
      final gallery = GalleryFake(
        access: GalleryAccess.limited,
        photos: [photo('p1'), photo('p2')],
        allowed: ['p1'],
      )..thumbnails['p1'] = photoPng;
      await pump(tester, ChatFake(), gallery);

      await openSheet(tester);

      expect(find.byKey(const ValueKey('sheet-photo-p1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sheet-photo-p2')),
        findsNothing,
        reason: 'a photo not in allowed was never granted',
      );
      expect(find.byKey(const ValueKey('sheet-allow-more')), findsOneWidget);
      expect(find.byType(GridView), findsOneWidget);
      expectNoAndroidPicker();
    });

    testWidgets('"Allow more" asks again and the grid shows what was added', (
      tester,
    ) async {
      final gallery =
          GalleryFake(
              access: GalleryAccess.limited,
              photos: [photo('p1'), photo('p2')],
              allowed: ['p1'],
            )
            ..reRequestAdds = {'p2'}
            ..thumbnails.addAll({'p1': photoPng, 'p2': photoPng});
      await pump(tester, ChatFake(), gallery);
      await openSheet(tester);
      expect(gallery.accessRequests, 1);
      expect(find.byKey(const ValueKey('sheet-photo-p2')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('sheet-allow-more')));
      await tester.pumpAndSettle();

      expect(
        gallery.accessRequests,
        2,
        reason: '"Allow more" re-requests access (the platform\'s prompt)',
      );
      expect(
        find.byKey(const ValueKey('sheet-photo-p2')),
        findsOneWidget,
        reason:
            'the member allowed a new photo; the sheet must re-read the '
            'grid to show it without being closed and reopened',
      );
      expect(gallery.openSettingsCalls, 0);
    });
  });

  group('denied', () {
    testWidgets('shows SIS\'s own screen with "Allow photos" and "Not now"', (
      tester,
    ) async {
      final gallery = GalleryFake(access: GalleryAccess.denied);
      await pump(tester, ChatFake(), gallery);

      await openSheet(tester);

      expectAccessScreen();
      expect(allowLabelled('Allow photos'), findsOneWidget);
      expect(allowLabelled('Open settings'), findsNothing);
      expect(gallery.accessRequests, 1);
      expectNoAndroidPicker();
    });

    testWidgets('"Allow photos" asks again and shows the grid once granted', (
      tester,
    ) async {
      final gallery = GalleryFake(access: GalleryAccess.denied)
        ..photos = [photo('p1')]
        ..thumbnails['p1'] = photoPng;
      await pump(tester, ChatFake(), gallery);
      await openSheet(tester);

      gallery.access = GalleryAccess.full;
      await tester.tap(find.byKey(const ValueKey('sheet-allow')));
      await tester.pumpAndSettle();

      expect(gallery.accessRequests, 2);
      expect(
        gallery.openSettingsCalls,
        0,
        reason: 'the system can still prompt: no detour through settings',
      );
      expect(find.byKey(const ValueKey('sheet-photo-p1')), findsOneWidget);
      expect(find.text('Send photos faster'), findsNothing);
    });

    testWidgets(
      'refused again, the same button becomes "Open settings" and opens them',
      (tester) async {
        final gallery = GalleryFake(access: GalleryAccess.denied);
        await pump(tester, ChatFake(), gallery);
        await openSheet(tester);

        // The member taps Allow and refuses the system prompt a second
        // time: from now on Android will not prompt again.
        gallery.access = GalleryAccess.permanentlyDenied;
        await tester.tap(find.byKey(const ValueKey('sheet-allow')));
        await tester.pumpAndSettle();

        expectAccessScreen();
        expect(allowLabelled('Open settings'), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('sheet-allow')));
        await tester.pumpAndSettle();

        expect(gallery.openSettingsCalls, 1);
        expect(
          gallery.accessRequests,
          2,
          reason: 'no prompt will show any more; asking again is pointless',
        );
      },
    );

    testWidgets('"Not now" closes the sheet and sends nothing', (tester) async {
      final chat = ChatFake();
      final gallery = GalleryFake(access: GalleryAccess.denied);
      await pump(tester, chat, gallery);
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'keep me',
      );
      await tester.pump();
      await openSheet(tester);

      await tester.tap(find.byKey(const ValueKey('sheet-not-now')));
      await tester.pumpAndSettle();

      expect(find.text('Send photos faster'), findsNothing);
      expect(chat.sentImages, isEmpty);
      expect(gallery.accessRequests, 1);
      expect(gallery.openSettingsCalls, 0);
      expect(composerText(tester), 'keep me');
      expect(find.byType(SisNotice), findsNothing);
    });
  });

  testWidgets('the access screen fits a small phone (360 x 640 dp)', (
    tester,
  ) async {
    await pump(tester, ChatFake(), GalleryFake(access: GalleryAccess.denied));
    tester.view.physicalSize = const Size(720, 1280);
    tester.view.devicePixelRatio = 2;
    await tester.pump();

    await openSheet(tester);

    expectAccessScreen();
    expect(
      tester.takeException(),
      isNull,
      reason: 'a clipped explainer (RenderFlex overflow) hides its button',
    );
  });

  group('permanently denied', () {
    testWidgets('shows the same screen, its button labelled "Open settings"', (
      tester,
    ) async {
      final gallery = GalleryFake(access: GalleryAccess.permanentlyDenied);
      await pump(tester, ChatFake(), gallery);

      await openSheet(tester);

      expectAccessScreen();
      expect(allowLabelled('Open settings'), findsOneWidget);
      expect(allowLabelled('Allow photos'), findsNothing);
      expectNoAndroidPicker();
    });

    testWidgets('"Open settings" opens the app\'s settings, never a prompt', (
      tester,
    ) async {
      final gallery = GalleryFake(access: GalleryAccess.permanentlyDenied);
      await pump(tester, ChatFake(), gallery);
      await openSheet(tester);

      await tester.tap(find.byKey(const ValueKey('sheet-allow')));
      await tester.pumpAndSettle();

      expect(gallery.openSettingsCalls, 1);
      expect(
        gallery.accessRequests,
        1,
        reason: 'Android will not prompt again: requesting does nothing',
      );
    });
  });

  group('an unreadable thumbnail', () {
    testWidgets('renders a quiet tile', (tester) async {
      // Deliberately no thumbnail bytes for p1: unreadable.
      final gallery = GalleryFake(photos: [photo('p1')]);
      await pump(tester, ChatFake(), gallery);
      await openSheet(tester);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('sheet-photo-p1')), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('a thumbnail still on its way (0.30.8)', () {
    testWidgets('the tick circle already works, Send sends that photo; the '
        'tile already opens it big', (tester) async {
      final gallery = GalleryFake(photos: [photo('p1')])
        ..thumbnails['p1'] = photoPng
        ..holdThumbnails();
      final chat = ChatFake();
      await pump(tester, chat, gallery);
      await tester.tap(find.byKey(const ValueKey('composer-attach')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('attach-photo')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(gallery.thumbnailIds, contains('p1'));
      expect(find.byType(Image), findsNothing, reason: 'no picture yet');

      await tester.tap(find.byKey(const ValueKey('sheet-photo-p1')));
      await frames(tester);
      expect(
        find.byKey(const ValueKey('preview-page')),
        findsOneWidget,
        reason: 'a tile with no picture yet is still a tap target',
      );
      await tester.tap(find.byKey(const ValueKey('preview-back')));
      await frames(tester);

      await tester.tap(find.byKey(const ValueKey('sheet-tick-p1')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('sheet-send')),
        findsOneWidget,
        reason: 'the tick on a tile with no picture yet still ticks it',
      );
      await tester.tap(find.byKey(const ValueKey('sheet-send')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      gallery.releaseThumbnails();
      await settleImages(tester);
      expect(chat.sentImages, hasLength(1));
    });
  });

  group('choosing photos', () {
    testWidgets('the tick circle ticks a photo and a second tap unticks it; '
        'nothing loads and nothing is sent until Send', (tester) async {
      final gallery = GalleryFake(photos: [photo('p1'), photo('p2')])
        ..thumbnails.addAll({'p1': photoPng, 'p2': photoPng});
      final chat = ChatFake();
      await pump(tester, chat, gallery);
      await openSheet(tester);
      expect(
        find.byKey(const ValueKey('sheet-send')),
        findsNothing,
        reason: 'nothing ticked: no Send',
      );

      await tick(tester, ['p1']);
      expect(find.text('Send 1 photo'), findsOneWidget);
      await tick(tester, ['p2']);
      expect(find.text('Send 2 photos'), findsOneWidget);
      await tick(tester, ['p1']);
      expect(find.text('Send 1 photo'), findsOneWidget, reason: 'unticked');
      await tick(tester, ['p2']);
      expect(find.byKey(const ValueKey('sheet-send')), findsNothing);

      expect(gallery.loadedIds, isEmpty, reason: 'a tick reads no photo');
      expect(chat.sentImages, isEmpty);
    });

    testWidgets('the tick circle says what it does to a screen reader', (
      tester,
    ) async {
      final sem = tester.ensureSemantics();
      final gallery = GalleryFake(photos: [photo('p1')])
        ..thumbnails['p1'] = photoPng;
      await pump(tester, ChatFake(), gallery);
      await openSheet(tester);
      final tickKey = find.byKey(const ValueKey('sheet-tick-p1'));
      expect(tester.getSemantics(tickKey), isSemantics(label: 'Select photo'));
      await tick(tester, ['p1']);
      expect(tester.getSemantics(tickKey), isSemantics(label: 'Selected'));
      // The drawn circle may be smaller; the tappable node is 44 dp.
      expect(
        tester.getSemantics(tickKey).rect.shortestSide,
        greaterThanOrEqualTo(44),
        reason: 'the tick circle is a 44 dp target',
      );
      sem.dispose();
    });

    testWidgets('a tap on a photo opens it big and never ticks it', (
      tester,
    ) async {
      final gallery = GalleryFake(photos: [photo('p1'), photo('p2')])
        ..thumbnails.addAll({'p1': photoPng, 'p2': photoPng});
      final chat = ChatFake();
      await pump(tester, chat, gallery);
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'typed',
      );
      await tester.pump();
      await openSheet(tester);

      await openViewer(tester, 'p2');
      expect(find.byKey(const ValueKey('preview-page')), findsOneWidget);
      expect(find.text('2 / 2'), findsOneWidget, reason: 'not on the tapped');
      expect(previewCaption(tester), 'typed');
      await tester.tap(find.byKey(const ValueKey('preview-back')));
      await frames(tester);

      expect(find.byKey(const ValueKey('preview-page')), findsNothing);
      expect(
        find.byKey(const ValueKey('sheet-send')),
        findsNothing,
        reason: 'a tap on the photo ticked it',
      );
      expect(chat.sentImages, isEmpty);
      expect(composerText(tester), 'typed');
    });

    testWidgets('a tick made in the big view shows on the grid', (
      tester,
    ) async {
      final gallery = GalleryFake(photos: [photo('p1'), photo('p2')])
        ..thumbnails.addAll({'p1': photoPng, 'p2': photoPng});
      await pump(tester, ChatFake(), gallery);
      await openSheet(tester);
      await tick(tester, ['p1']);

      await openViewer(tester, 'p2');
      await tester.tap(find.byKey(const ValueKey('preview-tick')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('preview-back')));
      await frames(tester);

      expect(find.text('Send 2 photos'), findsOneWidget);
    });

    testWidgets('Send in the big view with nothing ticked sends the viewed '
        'photo with the caption and closes everything', (tester) async {
      final gallery = GalleryFake(photos: [photo('p1'), photo('p2')])
        ..thumbnails.addAll({'p1': photoPng, 'p2': photoPng})
        ..loadResults['p2'] = shot(2);
      final chat = ChatFake();
      await pump(tester, chat, gallery);
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'from the view',
      );
      await tester.pump();
      await openSheet(tester);
      await openViewer(tester, 'p2');
      await previewSend(tester);
      await settleImages(tester);

      expect([for (final s in chat.sentImages) s.image.bytes], [shot(2).bytes]);
      expect(chat.sentImages.single.body, 'from the view');
      expect(composerText(tester), isEmpty);
      expect(find.byKey(const ValueKey('preview-page')), findsNothing);
      expect(find.byType(GridView), findsNothing, reason: 'grid still open');
    });

    testWidgets('Send sends exactly the ticked photos at once, in tick '
        'order, with the typed caption, and closes the grid; no preview', (
      tester,
    ) async {
      final gallery =
          GalleryFake(photos: [photo('p1'), photo('p2'), photo('p3')])
            ..thumbnails.addAll({
              'p1': photoPng,
              'p2': photoPng,
              'p3': photoPng,
            })
            ..loadResults['p1'] = shot(1)
            ..loadResults['p2'] = shot(2)
            ..loadResults['p3'] = shot(3);
      final chat = ChatFake();
      await pump(tester, chat, gallery);
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'from the grid',
      );
      await tester.pump();
      await openSheet(tester);

      await tick(tester, ['p3', 'p1']);
      await tester.tap(find.byKey(const ValueKey('sheet-send')));
      var sawPreview = false;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        sawPreview |= find
            .byKey(const ValueKey('preview-page'))
            .evaluate()
            .isNotEmpty;
      }
      await settleImages(tester);

      expect(sawPreview, isFalse, reason: 'Send went through a preview');
      expect(gallery.loadedIds, unorderedEquals(['p3', 'p1']));
      expect(
        [for (final s in chat.sentImages) s.image.bytes],
        [shot(3).bytes, shot(1).bytes],
        reason: 'exactly the ticked photos, in the order they were ticked',
      );
      expect([for (final s in chat.sentImages) s.body], ['from the grid', '']);
      expect(composerText(tester), isEmpty);
      expect(
        find.byType(GridView),
        findsNothing,
        reason: 'the grid must have closed once the photos were sent',
      );
    });

    testWidgets('an 11th tick is refused with a notice; 10 stay ticked', (
      tester,
    ) async {
      final gallery = GalleryFake(photos: photoLibrary(12));
      for (final p in gallery.photos) {
        gallery.thumbnails[p.id] = photoPng;
      }
      final chat = ChatFake();
      await pump(tester, chat, gallery);
      await openSheet(tester);

      await tick(tester, [for (var i = 0; i < 10; i++) 'p$i']);
      expect(find.byType(SisNotice), findsNothing, reason: '10 is allowed');
      expect(find.text('Send 10 photos'), findsOneWidget);

      await tick(tester, ['p10']);

      expect(find.text('Send 10 photos'), findsOneWidget);
      final shown = tester.widget<SisNotice>(find.byType(SisNotice));
      expect(shown.message, contains('10'));
      expect(shown.isError, isFalse);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();

      await sendTicked(tester);
      await settleImages(tester);
      expect(gallery.loadedIds, [for (var i = 0; i < 10; i++) 'p$i']);
      expect(chat.sentImages, hasLength(10));
    });

    testWidgets('a second Send while the photos are loading does nothing', (
      tester,
    ) async {
      final gallery = GalleryFake(photos: [photo('p1')])
        ..thumbnails['p1'] = photoPng
        ..holdLoad();
      final chat = ChatFake();
      await pump(tester, chat, gallery);
      await openSheet(tester);
      await tick(tester, ['p1']);

      await tester.tap(find.byKey(const ValueKey('sheet-send')));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey('sheet-send')),
        warnIfMissed: false,
      );
      await tester.pump();

      expect(gallery.loadedIds, [
        'p1',
      ], reason: 'a tap while a load is already in flight must be ignored');

      gallery.releaseLoad();
      await frames(tester);
      await settleImages(tester);
      expect(chat.sentImages, hasLength(1), reason: 'sent twice or never');
    });

    testWidgets('one photo of two that cannot be opened: a notice, and the '
        'one that can is sent', (tester) async {
      final gallery = GalleryFake(photos: [photo('p1'), photo('p2')])
        ..thumbnails.addAll({'p1': photoPng, 'p2': photoPng})
        ..loadResults['p1'] = shot(1)
        ..loadResults['p2'] = null;
      final chat = ChatFake();
      await pump(tester, chat, gallery);
      await openSheet(tester);
      await tick(tester, ['p1', 'p2']);

      await sendTicked(tester);

      final shown = tester.widget<SisNotice>(find.byType(SisNotice));
      expect(shown.isError, isTrue);
      expect(shown.message, 'Some photos could not be opened.');
      await settleImages(tester);
      expect([for (final s in chat.sentImages) s.image.bytes], [shot(1).bytes]);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });

    testWidgets(
      'photos that cannot be opened say so in a notice and keep the sheet '
      'open',
      (tester) async {
        final gallery = GalleryFake(photos: [photo('p1')])
          ..thumbnails['p1'] = photoPng
          ..loadResults['p1'] = null;
        final chat = ChatFake();
        await pump(tester, chat, gallery);
        await openSheet(tester);
        await tick(tester, ['p1']);

        await tester.tap(find.byKey(const ValueKey('sheet-send')));
        await tester.pump();
        await tester.pump();

        expect(find.byType(SisNotice), findsOneWidget);
        expect(
          tester.widget<SisNotice>(find.byType(SisNotice)).message,
          contains('could not be opened'),
        );
        expect(find.byType(SnackBar), findsNothing);
        expect(chat.sentImages, isEmpty);
        expect(
          find.byKey(const ValueKey('sheet-photo-p1')),
          findsOneWidget,
          reason: 'the sheet must still be open after a failed load',
        );
        // Not stuck "opening": Send reads it again on the next tap.
        gallery.loadResults.remove('p1');
        await tester.tap(find.byKey(const ValueKey('sheet-send')));
        await frames(tester);
        await settleImages(tester);
        expect(gallery.loadedIds, ['p1', 'p1']);
        expect(chat.sentImages, hasLength(1));
        // Lets the notice's own timer run out so it does not outlive the
        // test.
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(find.byType(SisNotice), findsNothing);
      },
    );
  });

  group('dismissing the sheet', () {
    testWidgets('sends nothing and keeps the typed caption', (tester) async {
      final chat = ChatFake();
      final gallery = GalleryFake(photos: [photo('p1')])
        ..thumbnails['p1'] = photoPng;
      await pump(tester, chat, gallery);
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'keep me',
      );
      await tester.pump();
      await openSheet(tester);

      // Android's back gesture: the member leaves without picking anything.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.byType(GridView), findsNothing);
      expect(chat.sentImages, isEmpty);
      expect(gallery.loadedIds, isEmpty);
      expect(composerText(tester), 'keep me');
      expect(find.byType(SisNotice), findsNothing);
    });
  });

  group('scrolling back past the newest photos', () {
    /// The sheet opened on a library of [n] photos, each read a little
    /// late, like the platform.
    Future<GalleryFake> openOn(
      WidgetTester tester,
      int n, {
      GalleryAccess access = GalleryAccess.full,
      Iterable<String> allowed = const [],
    }) async {
      final gallery = GalleryFake(
        access: access,
        photos: photoLibrary(n),
        allowed: allowed,
        latency: const Duration(milliseconds: 5),
      );
      await pump(tester, ChatFake(), gallery);
      await tester.tap(find.byKey(const ValueKey('composer-attach')));
      await steps(tester);
      await tester.tap(find.byKey(const ValueKey('attach-photo')));
      await steps(tester);
      expect(find.byKey(const ValueKey('sheet-photo-p0')), findsOneWidget);
      return gallery;
    }

    testWidgets('opens on the first page; asks for the next only near the '
        'bottom', (tester) async {
      final gallery = await openOn(tester, 200);
      await expectNextPageOnlyNearBottom(tester, gallery);
    });

    testWidgets('scrolls to the end: every page once, in order, and a short '
        'page ends it', (tester) async {
      final gallery = await openOn(tester, 2 * pageSize + 25);
      await expectPagesToEnd(tester, gallery, 2 * pageSize + 25);
    });

    testWidgets('a library of whole pages ends on the empty page after it, '
        'keeping every photo', (tester) async {
      final gallery = await openOn(tester, 2 * pageSize);
      await expectPagesToEnd(tester, gallery, 2 * pageSize);
      expect(find.text('No photos yet'), findsNothing);
    });

    testWidgets('a slow page shows the progress line and is asked for once', (
      tester,
    ) async {
      final gallery = await openOn(tester, 200);
      await expectSlowPage(tester, gallery);
    });

    testWidgets('a failed page says so, keeps the photos, and is retried on '
        'the next scroll', (tester) async {
      final gallery = await openOn(tester, 200);
      await expectFailureAndRetry(tester, gallery, 200);
    });

    testWidgets('limited access pages through only the allowed photos', (
      tester,
    ) async {
      final all = photoLibrary(300);
      final allowed = [
        for (var i = 0; i < all.length; i += 3) all[i].id,
      ]; // p0, p3, p6 ... : 100 of them, pages of 60 + 40
      final gallery = await openOn(
        tester,
        300,
        access: GalleryAccess.limited,
        allowed: allowed,
      );

      await scrollToEnd(tester);

      expect(pagesAsked(gallery), [0, 1]);
      expect(await gridOrder(tester), allowed);
      expect(find.byKey(const ValueKey('sheet-allow-more')), findsOneWidget);
    });

    group('a reload from page 0 makes a page in flight a no-op', () {
      Future<GalleryFake> openLimited(WidgetTester tester, List<String> a) =>
          openOn(
            tester,
            reloadLibrary,
            access: GalleryAccess.limited,
            allowed: a,
          );

      for (final staleLast in [true, false]) {
        final when = staleLast ? 'after' : 'before';
        testWidgets('a stale page arriving $when the fresh page 0 is '
            'dropped; paging restarts at page 1', (tester) async {
          final gallery = await openLimited(tester, reloadAllowed);
          await expectStalePageIgnored(tester, gallery, staleLast: staleLast);
        });

        testWidgets('a stale page failing $when the fresh page 0 says '
            'nothing and leaves the progress line alone', (tester) async {
          final gallery = await openLimited(tester, reloadAllowed);
          await expectStalePageIgnored(
            tester,
            gallery,
            staleLast: staleLast,
            fails: true,
          );
        });
      }

      for (final newestFirst in [true, false]) {
        testWidgets('two quick "Allow more" taps: only the newest reload '
            'shows (${newestFirst ? 'newest' : 'oldest'} completes '
            'first)', (tester) async {
          final gallery = await openLimited(
            tester,
            ids(photoLibrary(reloadLibrary)),
          );
          await expectNewestReloadWins(
            tester,
            gallery,
            newestFirst: newestFirst,
          );
        });
      }
    });
  });
}
