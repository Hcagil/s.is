import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/delivery_tick.dart';
import 'package:sis/app/notice.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/delivery.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/attach_flow.dart' hide key;
import '../../support/fakes.dart';
import '../../support/video_fakes.dart';
import '../../support/temp_device_files.dart';
import '../../support/file_fakes.dart';
import '../../support/l10n.dart';

import 'package:sis/l10n/app_localizations.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const capNotice = 'Only the first 10 photos were sent.';
final failNotice = l10nEn.attachOpenFailed;

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
  ExternalPickerFake picker, {
  DeviceFilesFake? files,
}) async {
  tester.view.physicalSize = const Size(1080, 2340);
  tester.view.devicePixelRatio = 2.625;
  addTearDown(tester.view.reset);
  final container = await settled(
    ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        deviceFilesProvider.overrideWithValue(files ?? tempDeviceFiles()),
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

Future<void> type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const ValueKey('composer-field')), text);
  await tester.pump();
}

Future<void> openSheet(WidgetTester tester) => openGrid(tester);

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

class _FlakyChat extends ChatFake {
  bool online = false;
  Failure? refuse;

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
    String? replyTo,
  }) async {
    if (refuse != null) return Err(refuse!);
    if (!online) {
      return const Err(NetworkFailure('No connection', retryable: true));
    }
    return super.sendImage(
      conversationId: conversationId,
      image: image,
      body: body,
      replyTo: replyTo,
    );
  }
}

/// The second copy fails after its file exists: the file is read-only, so the write throws.
class _HalfwayFailFiles extends DeviceFilesFake {
  _HalfwayFailFiles(String root) : super(onDisk: true, root: root);
  int _calls = 0;
  @override
  Future<String> pathFor(String messageId, String name) async {
    final path = await super.pathFor(messageId, name);
    if (++_calls == 2) {
      // A regular file that exists but cannot be written: the write throws.
      File(path).createSync();
      Process.runSync('chmod', ['444', path]);
    }
    return path;
  }
}

List<File> keptFiles(DeviceFilesFake f) {
  final dir = Directory(f.root);
  if (!dir.existsSync()) return [];
  return dir.listSync(recursive: true).whereType<File>().toList();
}

void main() {
  group('photo queue composer', () {
    testWidgets(
      'a photo that cannot be copied queues nothing and shows the save notice, the caption stays',
      (tester) async {
        final tempdir = Directory.systemTemp.createTempSync();
        addTearDown(() => tempdir.deleteSync(recursive: true));
        final blocker = File('${tempdir.path}/blocker');
        blocker.writeAsStringSync('x');
        final files = DeviceFilesFake(
          onDisk: true,
          root: '${tempdir.path}/blocker/files',
        );
        final chat = _FlakyChat()..online = true;
        final picker = ExternalPickerFake()..offered = [shot(1), shot(2)];
        await pump(
          tester,
          chat,
          galleryAt(GalleryAccess.full),
          picker,
          files: files,
        );
        await type(tester, 'cap');
        await openSheet(tester);
        await fromApp(tester);
        await steps(tester, 30);
        expect(chat.sentImages, isEmpty);
        expect(find.byKey(const ValueKey('attachment-local')), findsNothing);
        final n = notices(tester);
        expect(n, hasLength(1));
        expect(n.single.isError, isTrue);
        expect(n.single.message, l10nEn.failMessageSave);
        expect(composerText(tester), 'cap');
        await drain(tester);
      },
    );

    testWidgets(
      'a refused first photo stops the album, deletes the kept files and puts the caption back once',
      (tester) async {
        final tempdir = Directory.systemTemp.createTempSync();
        addTearDown(() => tempdir.deleteSync(recursive: true));
        final files = DeviceFilesFake(onDisk: true, root: tempdir.path);
        final chat = _FlakyChat()
          ..refuse = const NetworkFailure('refused', retryable: false);
        final picker = ExternalPickerFake()
          ..offered = [shot(1), shot(2), shot(3)];
        await pump(
          tester,
          chat,
          galleryAt(GalleryAccess.full),
          picker,
          files: files,
        );
        await type(tester, 'cap');
        await openSheet(tester);
        await fromApp(tester);
        await steps(tester, 30);
        expect(chat.sentImages, isEmpty);
        expect(keptFiles(files), isEmpty);
        expect(composerText(tester), 'cap');
        final n = notices(tester);
        expect(n, hasLength(1));
        expect(n.single.isError, isTrue);
        await drain(tester);
      },
    );

    testWidgets(
      'a photo sent offline waits as a pending bubble; back online it is sent once and still one bubble',
      (tester) async {
        final chat = _FlakyChat(); // offline by default
        final picker = ExternalPickerFake()..offered = [shot(1)];
        await pump(tester, chat, galleryAt(GalleryAccess.full), picker);
        await type(tester, 'cap');
        await openSheet(tester);
        await fromApp(tester);
        await steps(tester, 10);
        expect(find.byKey(const ValueKey('attachment-local')), findsOneWidget);
        expect(chat.sentImages, isEmpty);
        Set<String> bubbleKeys() => find
            .byWidgetPredicate(
              (w) =>
                  w.key is ValueKey<String> &&
                  (w.key as ValueKey<String>).value.startsWith('message-'),
            )
            .evaluate()
            .map((e) => (e.widget.key as ValueKey<String>).value)
            .toSet();
        final before = bubbleKeys();
        expect(before.length, 1);
        chat.online = true;
        await tester.pump(const Duration(seconds: 6));
        await steps(tester, 20);
        await drain(tester);
        expect(chat.sentImages.length, 1);
        expect(bubbleKeys().length, 1);
        expect(composerText(tester), '');
      },
    );

    for (final caption in ['album cap', '']) {
      testWidgets(
        'an album waiting offline shows exactly one pending clock (caption: "$caption"); once sent it is not pending',
        (tester) async {
          final chat = _FlakyChat(); // offline by default
          final picker = ExternalPickerFake()..offered = [shot(1), shot(2)];
          await pump(tester, chat, galleryAt(GalleryAccess.full), picker);
          if (caption.isNotEmpty) await type(tester, caption);
          await openSheet(tester);
          await fromApp(tester);
          await steps(tester, 10);
          final pendingTick = find.byWidgetPredicate(
            (w) => w is DeliveryTick && w.delivery == Delivery.pending,
          );
          expect(chat.sentImages, isEmpty);
          expect(
            pendingTick,
            findsOneWidget,
            reason: 'one clock per album row',
          );
          chat.online = true;
          await tester.pump(const Duration(seconds: 6));
          await steps(tester, 20);
          await drain(tester);
          expect(chat.sentImages.length, 2);
          expect(pendingTick, findsNothing);
        },
      );
    }

    testWidgets(
      'a copy that fails halfway leaves no file in the app folder (earlier copies too), queues nothing and shows the save notice',
      (tester) async {
        final tempdir = Directory.systemTemp.createTempSync();
        addTearDown(() => tempdir.deleteSync(recursive: true));
        final files = _HalfwayFailFiles(tempdir.path);
        final chat = _FlakyChat()..online = true;
        final picker = ExternalPickerFake()
          ..offered = [shot(1), shot(2), shot(3)];
        await pump(
          tester,
          chat,
          galleryAt(GalleryAccess.full),
          picker,
          files: files,
        );
        await type(tester, 'cap');
        await openSheet(tester);
        await fromApp(tester);
        await steps(tester, 30);
        expect(chat.sentImages, isEmpty);
        expect(find.byKey(const ValueKey('attachment-local')), findsNothing);
        final left = Directory(files.root).existsSync()
            ? Directory(files.root)
                  .listSync(recursive: true, followLinks: false)
                  .where((e) => e is File || e is Link)
                  .toList()
            : <FileSystemEntity>[];
        expect(left, isEmpty, reason: 'no copy, whole or partial, is left');
        final n = notices(tester);
        expect(n, hasLength(1));
        expect(n.single.isError, isTrue);
        expect(n.single.message, l10nEn.failMessageSave);
        expect(composerText(tester), 'cap');
        await drain(tester);
      },
    );
  });
}
