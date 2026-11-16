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

import '../../support/attach_flow.dart';
import '../../support/fakes.dart';
import '../../support/video_fakes.dart';

import 'package:sis/l10n/app_localizations.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

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

class _NoPicker implements ExternalPicker {
  @override
  Future<ExternalPickResult> takePhoto() async =>
      const ExternalPickCancelled();

  @override
  Future<ExternalPickResult> pickAttachments() async =>
      const ExternalPickCancelled();

  @override
  Future<ExternalPickResult> pickProfilePicture() async =>
      const ExternalPickCancelled();
}

void main() {
  testWidgets(
    'a caption typed before an album is sent with photo one and gone from the box when photo two fails',
    (tester) async {
      final chat = ChatFake();
      final gallery = GalleryFake(
        access: GalleryAccess.full,
        photos: const [GalleryPhoto('p1'), GalleryPhoto('p2')],
        allowed: const ['p1', 'p2'],
      )
        ..thumbnails['p1'] = photoPng
        ..thumbnails['p2'] = photoPng;
      gallery.loadResults['p2'] = PickedImage(
        bytes: photoPng,
        contentType: 'text/plain',
        extension: 'txt',
        preview: pngBytes,
      );

      await pump(tester, chat, gallery, _NoPicker());

      await steps(tester, 40);

      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'Sunset at the pier',
      );
      await tester.pump();

      await openGrid(tester);
      await tick(tester, ['p1', 'p2']);
      await sendTicked(tester);
      await drain(tester);

      expect(chat.sentImages.length, greaterThanOrEqualTo(1));
      expect(chat.sentImages[0].body, 'Sunset at the pier');

      final composer =
          tester.widget<TextField>(find.byKey(const ValueKey('composer-field')));
      expect(composer.controller!.text, '');

      expect(tester.takeException(), isNull);
    },
  );
}
