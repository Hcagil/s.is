// "From an app" in the attachment sheet, written from its contract (the
// 2026-09-28 decision and lib/features/chat/domain/external_picker.dart):
// the entry is on the grid and on the access screen at every access level,
// needs no photo permission, and what comes back is sent exactly like grid
// photos -- one message each, the caption on the first only, at most 10 with
// an SIS notice for the rest, stopping at the first failed send. Mounted
// through the real composer as production opens it; fakes only at the
// repository, gallery and external-picker boundaries.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/attach_flow.dart' hide key;
import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const capNotice = 'Only the first 10 photos were sent.';
const failNotice = 'That could not be opened.';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

/// A chat repository whose [holdAt]-th sendImage (1-based) waits for [gate]
/// before it is even received: an upload in flight, to see what the screen
/// shows before the batch is done.
class _HoldingChat extends ChatFake {
  _HoldingChat(this.holdAt);
  final int holdAt;
  final gate = Completer<void>();
  int sendCalls = 0;

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
    String? replyTo,
  }) async {
    if (++sendCalls == holdAt) await gate.future;
    return super.sendImage(
      conversationId: conversationId,
      image: image,
      body: body,
      replyTo: replyTo,
    );
  }
}

/// A chat repository that refuses the [refuseAt]-th upload (1-based), the
/// way the server refuses one: recorded, then an error.
class _RefusingChat extends ChatFake {
  _RefusingChat(this.refuseAt);
  final int refuseAt;
  int sendCalls = 0;

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
    String? replyTo,
  }) async {
    final result = await super.sendImage(
      conversationId: conversationId,
      image: image,
      body: body,
      replyTo: replyTo,
    );
    if (++sendCalls == refuseAt) {
      return const Err(NetworkFailure('The upload did not finish.'));
    }
    return result;
  }
}

/// A real, decodable photo told apart from its siblings by one trailing
/// byte after the PNG's end (decoders ignore it), with its tiny preview.
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
  ExternalPickerFake picker,
) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final container = await settled(
    ProviderContainer.test(
      overrides: [
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
      child: const MaterialApp(home: MessageScreen(title: 'Bob')),
    ),
  );
  await tester.pump();
}

Future<void> steps(WidgetTester tester, [int n = 20]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('composer-field')), text);
  await tester.pump();
}

// 0.30.10: the paperclip opens the grid itself, no menu in between.
Future<void> openSheet(WidgetTester tester) => openGrid(tester);

/// Taps "Gallery" and lets the round trip run: what comes back lands on the
/// preview page, whose Send (if it opened) is tapped so the sends run --
/// without letting any notice's timer run out.
Future<void> fromApp(WidgetTester tester) async {
  await tester.tap(fromAppEntry);
  await steps(tester);
  if (find.byKey(const ValueKey('preview-page')).evaluate().isNotEmpty) {
    await previewSend(tester);
  }
}

final fromAppEntry = find.byKey(const ValueKey('sheet-from-app'));

String composerText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('composer-field')),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

List<SisNotice> notices(WidgetTester tester) =>
    tester.widgetList<SisNotice>(find.byType(SisNotice)).toList();

Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  group('the entry is there at every access level', () {
    for (final access in [GalleryAccess.full, GalleryAccess.limited]) {
      testWidgets('${access.name}: a "Gallery" entry in the grid\'s '
          'header', (tester) async {
        await pump(tester, ChatFake(), galleryAt(access), ExternalPickerFake());
        await openSheet(tester);

        expect(find.byType(GridView), findsOneWidget);
        expect(fromAppEntry, findsOneWidget);
        expect(
          find.descendant(of: fromAppEntry, matching: find.text('Gallery')),
          findsOneWidget,
          reason: 'the header entry is labelled "Gallery" (0.30.10)',
        );
      });
    }

    for (final access in [
      GalleryAccess.denied,
      GalleryAccess.permanentlyDenied,
    ]) {
      testWidgets('${access.name}: a "Gallery" button on the access '
          'screen', (tester) async {
        await pump(tester, ChatFake(), galleryAt(access), ExternalPickerFake());
        await openSheet(tester);

        expect(find.byKey(const ValueKey('sheet-allow')), findsOneWidget);
        expect(find.byType(GridView), findsNothing);
        expect(fromAppEntry, findsOneWidget);
        expect(
          find.descendant(of: fromAppEntry, matching: find.text('Gallery')),
          findsOneWidget,
          reason: 'on the access screen the entry is a labelled button',
        );
      });
    }
  });

  group('photos from an app are sent like grid photos', () {
    for (final access in GalleryAccess.values) {
      testWidgets('${access.name}: one message per photo, in order, the '
          'caption on the first only; no permission asked, no settings '
          'opened', (tester) async {
        final chat = ChatFake();
        final gallery = galleryAt(access);
        final picker = ExternalPickerFake()
          ..offered = [shot(1), shot(2), shot(3)];
        await pump(tester, chat, gallery, picker);
        await type(tester, 'from the beach');
        await openSheet(tester);
        final asked = gallery.accessRequests;

        await fromApp(tester);

        expect(picker.attachmentCalls, 1);
        expect(picker.pictureCalls, 0, reason: 'a chat photo is no picture');
        expect(
          gallery.accessRequests,
          asked,
          reason: 'another app needs no photo permission from SIS',
        );
        expect(gallery.openSettingsCalls, 0);
        expect(gallery.loadedIds, isEmpty);
        expect(
          [for (final s in chat.sentImages) s.image.bytes],
          [shot(1).bytes, shot(2).bytes, shot(3).bytes],
        );
        expect(
          [for (final s in chat.sentImages) s.body],
          ['from the beach', '', ''],
        );
        expect(chat.sentImages.map((s) => s.conversationId).toSet(), {'c1'});
        expect(
          chat.sentImages.first.image.preview,
          pngBytes,
          reason: 'the tiny preview goes with the photo, as from the grid',
        );
        expect(composerText(tester), isEmpty);
        expect(find.byType(GridView), findsNothing);
        expect(find.text('Send photos faster'), findsNothing);
        expect(notices(tester), isEmpty);
      });
    }

    testWidgets('the caption stays in the composer until the last photo is '
        'sent', (tester) async {
      final chat = _HoldingChat(3);
      final picker = ExternalPickerFake()
        ..offered = [shot(1), shot(2), shot(3)];
      await pump(tester, chat, galleryAt(GalleryAccess.full), picker);
      await type(tester, 'hold on');
      await openSheet(tester);

      await fromApp(tester);
      expect(chat.sentImages, hasLength(2), reason: 'the third is in flight');
      expect(composerText(tester), 'hold on');

      chat.gate.complete();
      await steps(tester);
      expect(chat.sentImages, hasLength(3));
      expect(composerText(tester), isEmpty);
    });
  });

  group('more than 10', () {
    testWidgets('the first 10 are sent, then one notice (not an error) says '
        'so, after the last send', (tester) async {
      final chat = _HoldingChat(10);
      final picker = ExternalPickerFake()
        ..offered = [for (var i = 1; i <= 13; i++) shot(i)];
      await pump(tester, chat, galleryAt(GalleryAccess.full), picker);
      await type(tester, 'trip');
      await openSheet(tester);

      await fromApp(tester);
      expect(chat.sentImages, hasLength(9));
      expect(
        find.text(capNotice),
        findsNothing,
        reason: 'the notice comes after the last send, not before',
      );

      chat.gate.complete();
      await steps(tester);

      expect(
        [for (final s in chat.sentImages) s.image.bytes],
        [for (var i = 1; i <= 10; i++) shot(i).bytes],
      );
      expect(chat.sentImages.first.body, 'trip');
      expect(chat.sentImages.skip(1).every((s) => s.body.isEmpty), isTrue);
      final shown = notices(tester);
      expect(shown, hasLength(1), reason: 'shown once');
      expect(shown.single.message, capNotice);
      expect(shown.single.isError, isFalse);
      await drain(tester);
    });

    testWidgets('exactly 10: no notice', (tester) async {
      final chat = ChatFake();
      final picker = ExternalPickerFake()
        ..offered = [for (var i = 1; i <= 10; i++) shot(i)];
      await pump(tester, chat, galleryAt(GalleryAccess.full), picker);
      await openSheet(tester);

      await fromApp(tester);

      expect(chat.sentImages, hasLength(10));
      expect(notices(tester), isEmpty);
    });
  });

  group('a send that fails part way', () {
    testWidgets('keeps what was sent, says why, sends none of the rest and '
        'never claims the cap', (tester) async {
      // The third upload is refused. (0.30.10: every photo is shown on the
      // preview page first, so it must decode; the refusal comes from the
      // upload, as a real one does.)
      final chat = _RefusingChat(3);
      final picker = ExternalPickerFake()
        ..offered = [for (var i = 1; i <= 12; i++) shot(i)];
      await pump(tester, chat, galleryAt(GalleryAccess.full), picker);
      await type(tester, 'part way');
      await openSheet(tester);

      await fromApp(tester);

      expect(
        [for (final s in chat.sentImages) s.image.bytes],
        [shot(1).bytes, shot(2).bytes, shot(3).bytes],
        reason: 'the batch stops at the refused photo',
      );
      expect(find.byKey(const ValueKey('message-img-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('message-img-2')), findsOneWidget);
      final shown = notices(tester);
      expect(shown, hasLength(1));
      expect(shown.single.isError, isTrue);
      expect(find.text(capNotice), findsNothing);
      expect(
        composerText(tester),
        'part way',
        reason: 'a failed batch leaves the composer untouched',
      );
      await drain(tester);
      expect(find.text(capNotice), findsNothing);
    });
  });

  group('nothing comes back', () {
    testWidgets('backing out sends nothing, says nothing and keeps the '
        'caption', (tester) async {
      final chat = ChatFake();
      final gallery = galleryAt(GalleryAccess.denied);
      final picker = ExternalPickerFake();
      await pump(tester, chat, gallery, picker);
      await type(tester, 'keep me');
      await openSheet(tester);

      await fromApp(tester);

      expect(picker.attachmentCalls, 1);
      expect(chat.sentImages, isEmpty);
      expect(notices(tester), isEmpty);
      expect(composerText(tester), 'keep me');
      expect(gallery.accessRequests, 1);
      expect(gallery.openSettingsCalls, 0);
    });

    for (final access in [
      GalleryAccess.full,
      GalleryAccess.permanentlyDenied,
    ]) {
      testWidgets('${access.name}: not a photo -> "$failNotice", nothing '
          'sent', (tester) async {
        final chat = ChatFake();
        final gallery = galleryAt(access);
        final picker = ExternalPickerFake()..failure = true;
        await pump(tester, chat, gallery, picker);
        await type(tester, 'keep me');
        await openSheet(tester);

        await fromApp(tester);

        expect(chat.sentImages, isEmpty);
        final shown = notices(tester);
        expect(shown, hasLength(1));
        expect(shown.single.message, failNotice);
        expect(shown.single.isError, isTrue);
        expect(composerText(tester), 'keep me');
        expect(gallery.accessRequests, 1);
        expect(gallery.openSettingsCalls, 0);
        await drain(tester);
      });
    }
  });

  group('the camera tile (0.30.10)', () {
    Future<void> camera(WidgetTester tester) async {
      await openGrid(tester);
      await tester.tap(find.byKey(const ValueKey('sheet-camera')));
      await steps(tester);
      if (find.byKey(const ValueKey('preview-page')).evaluate().isNotEmpty) {
        await previewSend(tester);
      }
    }

    const cameraFailed = 'The camera could not take a photo.';

    testWidgets('a photo taken is sent to this chat as one image', (
      tester,
    ) async {
      final chat = ChatFake();
      final picker = ExternalPickerFake()..shot = shot(7);
      await pump(tester, chat, galleryAt(GalleryAccess.full), picker);

      await camera(tester);

      expect(picker.cameraCalls, 1);
      expect(picker.attachmentCalls, 0);
      expect(chat.sentImages, hasLength(1));
      expect(chat.sentImages.single.conversationId, 'c1');
      expect(chat.sentImages.single.image.bytes, shot(7).bytes);
      expect(notices(tester), isEmpty);
    });

    testWidgets('closing the camera without a photo is silent', (tester) async {
      final chat = ChatFake();
      final picker = ExternalPickerFake(); // shot stays null
      await pump(tester, chat, galleryAt(GalleryAccess.full), picker);
      await type(tester, 'keep me');

      await camera(tester);

      expect(picker.cameraCalls, 1);
      expect(chat.sentImages, isEmpty);
      expect(notices(tester), isEmpty);
      expect(composerText(tester), 'keep me');
    });

    for (final (name, broken) in [
      ('no usable camera', (ExternalPickerFake p) => p.noCamera = true),
      ('not a readable photo', (ExternalPickerFake p) => p.failure = true),
    ]) {
      testWidgets('$name -> "$cameraFailed", nothing sent', (tester) async {
        final chat = ChatFake();
        final picker = ExternalPickerFake()..shot = shot(1);
        broken(picker);
        await pump(tester, chat, galleryAt(GalleryAccess.full), picker);

        await camera(tester);

        expect(chat.sentImages, isEmpty);
        final shown = notices(tester);
        expect(shown, hasLength(1));
        expect(shown.single.message, cameraFailed);
        expect(shown.single.isError, isTrue);
        await drain(tester);
      });
    }
  });
}
