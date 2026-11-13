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

List<SisNotice> notices(WidgetTester tester) =>
    tester.widgetList<SisNotice>(find.byType(SisNotice)).toList();

Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// A camera whose platform call throws something that is NOT a
/// PlatformException -- e.g. a MissingPluginException or a cast error in
/// the channel code. Counts calls.
class _ThrowingCamera implements ExternalPicker {
  int cameraCalls = 0;
  @override
  Future<ExternalPickResult> takePhoto() async {
    cameraCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    throw StateError('camera channel broke');
  }

  @override
  Future<ExternalPickResult> pickAttachments() async =>
      const ExternalPickCancelled();

  @override
  Future<ExternalPickResult> pickProfilePicture() async =>
      const ExternalPickCancelled();
}

void main() {
  group('camera photo send never fails silently', () {
    testWidgets(
      'a camera that throws shows "The camera could not take a photo." and sends nothing',
      (tester) async {
        final chat = ChatFake();
        final picker = _ThrowingCamera();
        await pump(tester, chat, galleryAt(GalleryAccess.full), picker);

        await openGrid(tester);
        await tester.tap(find.byKey(const ValueKey('sheet-camera')));
        await steps(tester);

        expect(picker.cameraCalls, 1);
        expect(chat.sentImages, isEmpty);

        final shown = notices(tester);
        expect(shown, hasLength(1));
        expect(shown.single.message, 'The camera could not take a photo.');
        expect(shown.single.isError, isTrue);

        await drain(tester);
      },
    );

    testWidgets(
      'after a camera that throws, the camera tile can be tapped again',
      (tester) async {
        final chat = ChatFake();
        final picker = _ThrowingCamera();
        await pump(tester, chat, galleryAt(GalleryAccess.full), picker);

        await openGrid(tester);
        await tester.tap(find.byKey(const ValueKey('sheet-camera')));
        await steps(tester);
        await drain(tester);

        await tester.tap(find.byKey(const ValueKey('sheet-camera')));
        await steps(tester);

        expect(picker.cameraCalls, 2);
        await drain(tester);
      },
    );
  });
}
