// The attachment sheet, written from its contract in
// lib/features/chat/domain/gallery.dart and
// lib/features/chat/presentation/attachment_sheet.dart: what a member sees
// at each access level, what tapping a photo, "Select more" or "Allow
// access" actually does, and how the composer wires the sheet's outcome to
// MessagesController -- never how the sheet is built. Mounted through the
// real composer, exactly as production opens it: entry to the sheet is not
// a fixture, it's part of the contract.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

Future<ProviderContainer> _scope(
  ChatFake chat,
  Gallery gallery,
  AttachmentSource picker,
) => settled(
  ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(chat),
      presenceRepositoryProvider.overrideWithValue(PresenceFake()),
      galleryProvider.overrideWithValue(gallery),
      attachmentSourceProvider.overrideWithValue(picker),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  ),
);

Future<ProviderContainer> pump(
  WidgetTester tester,
  ChatFake chat,
  Gallery gallery, {
  AttachmentSource? picker,
}) async {
  final container = await _scope(chat, gallery, picker ?? PickerFake.cancels());
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

void main() {
  group('access states', () {
    testWidgets('full access with photos shows a 3-wide grid', (tester) async {
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
      expect(
        find.byKey(const ValueKey('sheet-system-picker')),
        findsOneWidget,
        reason: 'All photos must stay reachable even with full access',
      );
      final delegate =
          tester.widget<GridView>(find.byType(GridView)).gridDelegate
              as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, 3);
      expect(gallery.accessRequests, 1);
    });

    testWidgets('full access with no photos says so plainly', (tester) async {
      await pump(tester, ChatFake(), GalleryFake());

      await openSheet(tester);

      expect(find.text('No photos yet'), findsOneWidget);
      expect(find.byKey(const ValueKey('sheet-system-picker')), findsOneWidget);
    });

    testWidgets(
      'limited access shows only what was allowed, plus Select more',
      (tester) async {
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
        expect(find.byKey(const ValueKey('sheet-select-more')), findsOneWidget);
      },
    );

    testWidgets('Select more actually reloads the grid, not just once', (
      tester,
    ) async {
      final gallery =
          GalleryFake(
              access: GalleryAccess.limited,
              photos: [photo('p1'), photo('p2')],
              allowed: ['p1'],
            )
            ..selectMoreAdds = {'p2'}
            ..thumbnails.addAll({'p1': photoPng, 'p2': photoPng});
      await pump(tester, ChatFake(), gallery);
      await openSheet(tester);
      expect(find.byKey(const ValueKey('sheet-photo-p2')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('sheet-select-more')));
      await tester.pumpAndSettle();

      expect(gallery.selectMoreCalls, 1);
      expect(
        find.byKey(const ValueKey('sheet-photo-p2')),
        findsOneWidget,
        reason:
            'selectMore() granted a new photo; the sheet must re-read the '
            'grid to show it without being closed and reopened',
      );
    });

    testWidgets('denied access explains itself and offers "All photos"', (
      tester,
    ) async {
      final gallery = GalleryFake(access: GalleryAccess.denied);
      await pump(tester, ChatFake(), gallery);

      await openSheet(tester);

      expect(find.byKey(const ValueKey('sheet-allow')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sheet-system-picker')),
        findsOneWidget,
        reason: 'All photos must stay available even when denied',
      );
      expect(find.byType(GridView), findsNothing);
      expect(gallery.accessRequests, 1);
    });

    testWidgets('"Allow access" asks again and shows the grid once granted', (
      tester,
    ) async {
      final gallery = GalleryFake(access: GalleryAccess.denied)
        ..photos = [photo('p1')]
        ..thumbnails['p1'] = photoPng;
      await pump(tester, ChatFake(), gallery);
      await openSheet(tester);
      expect(find.byKey(const ValueKey('sheet-allow')), findsOneWidget);

      gallery.access = GalleryAccess.full;
      await tester.tap(find.byKey(const ValueKey('sheet-allow')));
      await tester.pumpAndSettle();

      expect(gallery.accessRequests, 2);
      expect(find.byKey(const ValueKey('sheet-photo-p1')), findsOneWidget);
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
    testWidgets(
      'sends exactly the tapped photo, never the system picker, and closes '
      'the sheet',
      (tester) async {
        final chosen = PickedImage(
          bytes: photoPng,
          contentType: 'image/png',
          extension: 'png',
        );
        final gallery = GalleryFake(photos: [photo('p1'), photo('p2')])
          ..thumbnails.addAll({'p1': photoPng, 'p2': photoPng})
          ..loadResults['p2'] = chosen;
        final chat = ChatFake();
        final picker = PickerFake.returns(pickedPng());
        await pump(tester, chat, gallery, picker: picker);
        await tester.enterText(
          find.byKey(const ValueKey('composer-field')),
          'from the grid',
        );
        await tester.pump();
        await openSheet(tester);

        await tester.tap(find.byKey(const ValueKey('sheet-photo-p2')));
        await settleImages(tester);

        expect(gallery.loadedIds, ['p2']);
        expect(
          picker.calls,
          0,
          reason:
              'a photo chosen from the sheet\'s own grid must never touch '
              'the system picker',
        );
        expect(chat.sentImages, hasLength(1));
        expect(chat.sentImages.single.body, 'from the grid');
        expect(
          chat.sentImages.single.image.bytes,
          photoPng,
          reason: 'the exact photo tapped must be what is uploaded',
        );
        expect(composerText(tester), isEmpty);
        expect(
          find.byKey(const ValueKey('sheet-system-picker')),
          findsNothing,
          reason: 'the sheet must have closed once a photo was chosen',
        );
      },
    );

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
      'a photo that cannot be opened shows a SnackBar and keeps the sheet '
      'open',
      (tester) async {
        final gallery = GalleryFake(photos: [photo('p1')])
          ..thumbnails['p1'] = photoPng
          ..loadResults['p1'] = null;
        final chat = ChatFake();
        await pump(tester, chat, gallery);
        await openSheet(tester);

        await tester.tap(find.byKey(const ValueKey('sheet-photo-p1')));
        await tester.pumpAndSettle();

        expect(find.textContaining('could not be opened'), findsOneWidget);
        expect(chat.sentImages, isEmpty);
        expect(
          find.byKey(const ValueKey('sheet-photo-p1')),
          findsOneWidget,
          reason: 'the sheet must still be open after a failed load',
        );
        // Drains the SnackBar's own timer so it does not outlive the test.
        await tester.pumpAndSettle(const Duration(seconds: 6));
      },
    );
  });

  group('"All photos"', () {
    testWidgets('opens the system picker instead of the sheet\'s own grid', (
      tester,
    ) async {
      final chat = ChatFake();
      final picker = PickerFake.returns(pickedPng());
      final gallery = GalleryFake(photos: [photo('p1')])
        ..thumbnails['p1'] = photoPng;
      await pump(tester, chat, gallery, picker: picker);
      await openSheet(tester);

      await tester.tap(find.byKey(const ValueKey('sheet-system-picker')));
      await settleImages(tester);

      expect(picker.calls, 1);
      expect(
        gallery.loadedIds,
        isEmpty,
        reason:
            'the sheet\'s own load() must never be called for the '
            'system picker path',
      );
      expect(chat.sentImages.single.image.bytes, pngBytes);
    });
  });

  group('dismissing the sheet', () {
    testWidgets('sends nothing and keeps the typed caption', (tester) async {
      final chat = ChatFake();
      final picker = PickerFake.returns(pickedPng());
      await pump(tester, chat, GalleryFake(), picker: picker);
      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'keep me',
      );
      await tester.pump();
      await openSheet(tester);

      // Drags the sheet closed, the way a member backs out without picking
      // anything -- "All photos" and the grid both untouched.
      await tester.drag(find.byType(BottomSheet), const Offset(0, 400));
      await tester.pumpAndSettle();

      expect(chat.sentImages, isEmpty);
      expect(picker.calls, 0);
      expect(composerText(tester), 'keep me');
      expect(find.byType(SnackBar), findsNothing);
    });
  });
}
