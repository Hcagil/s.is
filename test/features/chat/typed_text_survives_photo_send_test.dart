import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/external_picker.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/attach_flow.dart';
import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

import 'package:sis/l10n/app_localizations.dart';

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

Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

class _Camera implements ExternalPicker {
  @override
  Future<ExternalPickResult> takePhoto() async =>
      ExternalPickedImages([shot(1)]);

  @override
  Future<ExternalPickResult> pickAttachments() async =>
      const ExternalPickCancelled();

  @override
  Future<ExternalPickResult> pickProfilePicture() async =>
      const ExternalPickCancelled();
}

void main() {
  group('text typed while a photo is sending stays in the write box', () {
    testWidgets(
      'ticked photo: text typed during the upload is still in the box after it finishes',
      (tester) async {
        final chat = ChatFake();
        await pump(tester, chat, galleryAt(GalleryAccess.full), _Camera());

        chat.holdSendImage();

        await openGrid(tester);
        await tick(tester, ['p1']);
        await sendTicked(tester);

        expect(chat.sentImages, hasLength(1));
        expect(chat.sentImages.single.body, '');

        await tester.enterText(key('composer-field'), 'typed while sending');
        await tester.pump();

        expect(
          tester.widget<TextField>(key('composer-field')).controller!.text,
          'typed while sending',
        );

        chat.releaseSendImage();
        await steps(tester);

        expect(
          tester.widget<TextField>(key('composer-field')).controller!.text,
          'typed while sending',
          reason:
              'text typed during the upload was wiped when the send finished',
        );

        await drain(tester);
      },
    );

    testWidgets(
      'camera photo: text typed during the upload is still in the box after it finishes',
      (tester) async {
        final chat = ChatFake();
        await pump(tester, chat, galleryAt(GalleryAccess.full), _Camera());

        chat.holdSendImage();

        await openGrid(tester);
        await tester.tap(key('sheet-camera'));
        await steps(tester);

        expect(chat.sentImages, hasLength(1));
        expect(chat.sentImages.single.body, '');

        await tester.enterText(key('composer-field'), 'typed while sending');
        await tester.pump();

        expect(
          tester.widget<TextField>(key('composer-field')).controller!.text,
          'typed while sending',
        );

        chat.releaseSendImage();
        await steps(tester);

        expect(
          tester.widget<TextField>(key('composer-field')).controller!.text,
          'typed while sending',
          reason:
              'text typed during the upload was wiped when the send finished',
        );

        await drain(tester);
      },
    );
  });
}
