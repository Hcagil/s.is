// The attachment sheet, written from its contract in
// lib/features/chat/domain/gallery.dart and
// lib/features/chat/presentation/attachment_sheet.dart: what a member sees
// at each access level (full, limited, denied, permanently denied), what
// tapping a photo, "Allow more", "Allow photos", "Open settings" or "Not
// now" actually does, and how the composer wires the sheet's outcome to
// MessagesController -- never how the sheet is built. Mounted through the
// real composer, exactly as production opens it: entry to the sheet is not
// a fixture, it's part of the contract.
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

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

GalleryPhoto photo(String id) => GalleryPhoto(id);

Future<ProviderContainer> _scope(ChatFake chat, Gallery gallery) => settled(
  ProviderContainer.test(
    overrides: [
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
      child: const MaterialApp(home: MessageScreen(title: 'Bob')),
    ),
  );
  await tester.pump();
  return container;
}

Future<void> openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('composer-attach')));
  await tester.pumpAndSettle();
}

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
    testWidgets('renders a quiet tile that does not respond to taps', (
      tester,
    ) async {
      // Deliberately no thumbnail bytes for p1: unreadable.
      final gallery = GalleryFake(photos: [photo('p1')]);
      await pump(tester, ChatFake(), gallery);
      await openSheet(tester);
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsNothing);

      await tester.tap(find.byKey(const ValueKey('sheet-photo-p1')));
      await tester.pumpAndSettle();

      expect(
        gallery.loadedIds,
        isEmpty,
        reason: 'a tile with no readable thumbnail must not be a tap target',
      );
    });
  });

  group('choosing a photo', () {
    testWidgets('sends exactly the tapped photo and closes the sheet', (
      tester,
    ) async {
      final chosen = PickedImage(
        bytes: photoPng,
        contentType: 'image/png',
        extension: 'png',
      );
      final gallery = GalleryFake(photos: [photo('p1'), photo('p2')])
        ..thumbnails.addAll({'p1': photoPng, 'p2': photoPng})
        ..loadResults['p2'] = chosen;
      final chat = ChatFake();
      await pump(tester, chat, gallery);
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'from the grid',
      );
      await tester.pump();
      await openSheet(tester);

      await tester.tap(find.byKey(const ValueKey('sheet-photo-p2')));
      await settleImages(tester);

      expect(gallery.loadedIds, ['p2']);
      expect(chat.sentImages, hasLength(1));
      expect(chat.sentImages.single.body, 'from the grid');
      expect(
        chat.sentImages.single.image.bytes,
        photoPng,
        reason: 'the exact photo tapped must be what is uploaded',
      );
      expect(composerText(tester), isEmpty);
      expect(
        find.byType(GridView),
        findsNothing,
        reason: 'the sheet must have closed once a photo was chosen',
      );
    });

    testWidgets('a second tap while the first is loading does nothing', (
      tester,
    ) async {
      final gallery = GalleryFake(photos: [photo('p1')])
        ..thumbnails['p1'] = photoPng
        ..holdLoad();
      await pump(tester, ChatFake(), gallery);
      await openSheet(tester);

      await tester.tap(find.byKey(const ValueKey('sheet-photo-p1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('sheet-photo-p1')));
      await tester.pump();

      expect(gallery.loadedIds, [
        'p1',
      ], reason: 'a tap while a load is already in flight must be ignored');

      gallery.releaseLoad();
      await settleImages(tester);
    });

    testWidgets(
      'a photo that cannot be opened says so in a notice and keeps the sheet '
      'open',
      (tester) async {
        final gallery = GalleryFake(photos: [photo('p1')])
          ..thumbnails['p1'] = photoPng
          ..loadResults['p1'] = null;
        final chat = ChatFake();
        await pump(tester, chat, gallery);
        await openSheet(tester);

        await tester.tap(find.byKey(const ValueKey('sheet-photo-p1')));
        await tester.pump();
        await tester.pump();

        expect(find.byType(SisNotice), findsOneWidget);
        expect(find.textContaining('could not be opened'), findsOneWidget);
        expect(find.byType(SnackBar), findsNothing);
        expect(chat.sentImages, isEmpty);
        expect(
          find.byKey(const ValueKey('sheet-photo-p1')),
          findsOneWidget,
          reason: 'the sheet must still be open after a failed load',
        );
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
}
