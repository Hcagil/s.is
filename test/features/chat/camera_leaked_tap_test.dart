import 'dart:async';
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
import 'package:sis/features/chat/domain/external_picker.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/attach_flow.dart' hide key;
import '../../support/fakes.dart';

import 'package:sis/l10n/app_localizations.dart';

import '../../support/video_fakes.dart';
import '../../support/temp_device_files.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

PickedImage shot(int i) => PickedImage(
  bytes: Uint8List.fromList([...photoPng, i]),
  contentType: 'image/jpeg',
  extension: 'jpg',
  preview: pngBytes,
);

GalleryFake galleryAt(GalleryAccess access) => GalleryFake(
  access: access,
  photos: const [GalleryPhoto('p1')],
  allowed: const ['p1'],
)..thumbnails['p1'] = photoPng;

Future<void> pump(
  WidgetTester tester,
  ChatFake chat,
  Gallery gallery,
  ExternalPicker picker,
) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        deviceFilesProvider.overrideWithValue(tempDeviceFiles()),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        galleryProvider.overrideWithValue(gallery),
        externalPickerProvider.overrideWithValue(picker),
        sessionControllerProvider.overrideWith(_SignedIn.new),
      ],
    ),
  );
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
}

Future<void> steps(WidgetTester tester, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

List<SisNotice> notices(WidgetTester tester) =>
    tester.widgetList<SisNotice>(find.byType(SisNotice)).toList();

Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

class _ThrowingPicker extends ExternalPickerFake {
  final Completer<void> gate = Completer<void>();

  @override
  Future<ExternalPickResult> takePhoto() async {
    cameraCalls++;
    await gate.future;
    throw Exception('camera crashed');
  }
}

void main() {
  group('a tap that leaks through while a native picker is open', () {
    testWidgets(
      'camera: a leaked tap on the barrier keeps the sheet open and the photo is sent',
      (tester) async {
        final chat = ChatFake();
        final picker = ExternalPickerFake()
          ..shot = shot(7)
          ..hold();

        await pump(tester, chat, galleryAt(GalleryAccess.full), picker);

        await openGrid(tester);
        await tester.tap(find.byKey(const ValueKey('sheet-camera')));
        await steps(tester);

        expect(picker.cameraCalls, 1);

        // leaked tap
        await tester.tapAt(const Offset(10, 10));
        await steps(tester);

        expect(
          find.byKey(const ValueKey('sheet-camera')),
          findsOneWidget,
          reason: 'the leaked tap closed the attachment sheet',
        );

        picker.release();
        await steps(tester);

        if (find.byKey(const ValueKey('preview-page')).evaluate().isNotEmpty) {
          await previewSend(tester);
        }

        expect(
          chat.sentImages,
          hasLength(1),
          reason: 'the camera photo was dropped',
        );
        expect(chat.sentImages.single.image.bytes, shot(7).bytes);
        expect(chat.sentImages.single.conversationId, 'c1');

        await drain(tester);
      },
    );

    testWidgets(
      'camera: a leaked tap on a photo in the grid does nothing and the photo is sent',
      (tester) async {
        final chat = ChatFake();
        final picker = ExternalPickerFake()
          ..shot = shot(7)
          ..hold();

        await pump(tester, chat, galleryAt(GalleryAccess.full), picker);

        await openGrid(tester);
        await tester.tap(find.byKey(const ValueKey('sheet-camera')));
        await steps(tester);

        expect(picker.cameraCalls, 1);

        // leaked tap on photo grid tile
        await tester.tapAt(
          tester.getCenter(find.byKey(const ValueKey('sheet-photo-p1'))),
        );
        await steps(tester);

        expect(
          find.byKey(const ValueKey('preview-page')),
          findsNothing,
          reason:
              'the leaked tap opened the photo p1 while the camera was open',
        );

        expect(
          find.byKey(const ValueKey('sheet-camera')),
          findsOneWidget,
          reason: 'the leaked tap closed the attachment sheet',
        );

        picker.release();
        await steps(tester);

        if (find.byKey(const ValueKey('preview-page')).evaluate().isNotEmpty) {
          await previewSend(tester);
        }

        expect(
          chat.sentImages,
          hasLength(1),
          reason: 'the camera photo was dropped',
        );
        expect(chat.sentImages.single.image.bytes, shot(7).bytes);
        expect(chat.sentImages.single.conversationId, 'c1');

        await drain(tester);
      },
    );

    testWidgets(
      'phone photo picker: a leaked tap on the barrier keeps the sheet open and the photo is sent',
      (tester) async {
        final chat = ChatFake();
        final picker = ExternalPickerFake()
          ..offered = [shot(3)]
          ..hold();

        await pump(tester, chat, galleryAt(GalleryAccess.full), picker);

        await openGrid(tester);
        await tester.tap(find.byKey(const ValueKey('sheet-from-app')));
        await steps(tester);

        expect(picker.attachmentCalls, 1);

        // leaked tap
        await tester.tapAt(const Offset(10, 10));
        await steps(tester);

        expect(
          find.byKey(const ValueKey('sheet-from-app')),
          findsOneWidget,
          reason: 'the leaked tap closed the attachment sheet',
        );

        picker.release();
        await steps(tester);

        if (find.byKey(const ValueKey('preview-page')).evaluate().isNotEmpty) {
          await previewSend(tester);
        }

        expect(
          chat.sentImages,
          hasLength(1),
          reason: 'the picked photo was dropped',
        );
        expect(chat.sentImages.single.image.bytes, shot(3).bytes);
        expect(chat.sentImages.single.conversationId, 'c1');

        await drain(tester);
      },
    );

    // NEW TESTS

    for (final access in [
      GalleryAccess.denied,
      GalleryAccess.permanentlyDenied,
    ]) {
      testWidgets(
        '${access.name}: Gallery, a leaked tap on the barrier keeps the sheet open and the photo is sent',
        (tester) async {
          final chat = ChatFake();
          final picker = ExternalPickerFake()
            ..offered = [shot(3)]
            ..hold();

          await pump(tester, chat, galleryAt(access), picker);

          // open denied screen
          await tester.tap(find.byKey(const ValueKey('composer-attach')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('attach-photo')));
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const ValueKey('sheet-from-app')));
          await steps(tester);

          expect(picker.attachmentCalls, 1);

          // leaked tap
          await tester.tapAt(const Offset(10, 10));
          await steps(tester);

          expect(
            find.byKey(const ValueKey('sheet-from-app')),
            findsOneWidget,
            reason: 'the leaked tap closed the attachment sheet',
          );

          picker.release();
          await steps(tester);

          if (find
              .byKey(const ValueKey('preview-page'))
              .evaluate()
              .isNotEmpty) {
            await previewSend(tester);
          }

          expect(
            chat.sentImages,
            hasLength(1),
            reason: 'the picked photo was dropped',
          );
          expect(chat.sentImages.single.image.bytes, shot(3).bytes);
          expect(chat.sentImages.single.conversationId, 'c1');

          await drain(tester);
        },
      );
    }

    testWidgets(
      'camera: a back press while the camera is open does not close the sheet',
      (tester) async {
        final chat = ChatFake();
        final picker = ExternalPickerFake()
          ..shot = shot(7)
          ..hold();

        await pump(tester, chat, galleryAt(GalleryAccess.full), picker);

        await openGrid(tester);
        await tester.tap(find.byKey(const ValueKey('sheet-camera')));
        await steps(tester);

        await tester.binding.handlePopRoute();
        await steps(tester);

        expect(
          find.byKey(const ValueKey('sheet-camera')),
          findsOneWidget,
          reason: 'sheet should stay open after back press',
        );
        expect(
          find.byType(MessageScreen),
          findsOneWidget,
          reason: 'main screen should still be present',
        );

        picker.release();
        await steps(tester);

        if (find.byKey(const ValueKey('preview-page')).evaluate().isNotEmpty) {
          await previewSend(tester);
        }

        expect(
          chat.sentImages,
          hasLength(1),
          reason: 'the camera photo was dropped',
        );
        expect(chat.sentImages.single.image.bytes, shot(7).bytes);
        expect(chat.sentImages.single.conversationId, 'c1');

        await drain(tester);
      },
    );

    testWidgets(
      'camera: cancel after a leaked tap releases the guard (a barrier tap now closes the sheet) and sends nothing',
      (tester) async {
        final chat = ChatFake();
        final picker = ExternalPickerFake()
          ..shot = null
          ..hold();

        await pump(tester, chat, galleryAt(GalleryAccess.full), picker);

        await openGrid(tester);
        await tester.tap(find.byKey(const ValueKey('sheet-camera')));
        await steps(tester);

        // leaked tap
        await tester.tapAt(const Offset(10, 10));
        await steps(tester);

        expect(
          find.byKey(const ValueKey('sheet-camera')),
          findsOneWidget,
          reason: 'a cancel keeps the grid open',
        );

        picker.release();
        await steps(tester);

        await tester.tapAt(const Offset(10, 10));
        await steps(tester, 40);

        expect(
          find.byKey(const ValueKey('sheet-camera')),
          findsNothing,
          reason: 'the guard stayed set after the cancel: the barrier tap was ignored',
        );
        expect(chat.sentImages, isEmpty, reason: 'no image should be sent');
        expect(notices(tester), isEmpty, reason: 'no notices should appear');

        await drain(tester);
      },
    );

    testWidgets(
      'camera: an exception from the camera releases the guard (a barrier tap now closes the sheet) and shows the error notice',
      (tester) async {
        final chat = ChatFake();
        final picker = _ThrowingPicker()..hold();

        await pump(tester, chat, galleryAt(GalleryAccess.full), picker);

        await openGrid(tester);
        await tester.tap(find.byKey(const ValueKey('sheet-camera')));
        await steps(tester);

        // leaked tap
        await tester.tapAt(const Offset(10, 10));
        await steps(tester);

        expect(
          find.byKey(const ValueKey('sheet-camera')),
          findsOneWidget,
          reason: 'sheet should stay open while exception is pending',
        );

        picker.gate.complete();
        await steps(tester);

        expect(
          find.byKey(const ValueKey('sheet-camera')),
          findsOneWidget,
          reason: 'a failure keeps the grid open',
        );
        expect(
          notices(tester),
          hasLength(1),
          reason: 'one error notice should appear',
        );
        expect(
          notices(tester).single.message,
          'The camera could not take a photo.',
          reason: 'error message should match',
        );
        expect(
          notices(tester).single.isError,
          isTrue,
          reason: 'notice should be marked as error',
        );
        await tester.tapAt(const Offset(10, 10));
        await steps(tester, 40);
        expect(
          find.byKey(const ValueKey('sheet-camera')),
          findsNothing,
          reason: 'the guard stayed set after the exception',
        );

        expect(chat.sentImages, isEmpty, reason: 'no image should be sent');

        await drain(tester);
      },
    );
  });
}
