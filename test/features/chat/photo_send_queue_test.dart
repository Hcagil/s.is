import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/attachment.dart';

import '../../support/file_fakes.dart';
import '../../support/held_image_chat.dart';
import '../../support/held_send_chat.dart';
import '../../support/video_fakes.dart';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

const offline = NetworkFailure('No connection', retryable: true);
const refusal = NetworkFailure('refused', retryable: false);

/// The queue makes each photo's client message id itself.
List<String> ids(ProviderContainer c) => [
  for (final m in c.read(sendQueueProvider)['c1'] ?? const <Message>[]) m.id,
];

/// Frames plus real time: the fake phone folder answers a little late.
Future<void> hop(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    for (var j = 0; j < 5; j++) {
      await t.pump(const Duration(milliseconds: 5));
    }
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
}

Future<ProviderContainer> start(
  WidgetTester t,
  HeldImageChat chat,
  DeviceFilesFake files,
) async {
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(),
      chatRepositoryProvider.overrideWithValue(chat),
      sessionControllerProvider.overrideWith(_SignedIn.new),
      deviceFilesProvider.overrideWithValue(files),
    ],
  );
  c.listen(sessionControllerProvider, (_, _) {});
  c.listen(sendQueueProvider, (_, _) {});
  await hop(t);
  await t.pump(const Duration(milliseconds: 1));
  expect(c.read(sessionControllerProvider).value, isA<Allowed>());
  return c;
}

List<File> kept(DeviceFilesFake files) {
  final dir = Directory(files.root);
  if (!dir.existsSync()) return [];
  return dir.listSync(recursive: true).whereType<File>().toList();
}

PickedImage img(String id) => PickedImage(
  bytes: Uint8List.fromList([1, 2, 3, id.codeUnitAt(1)]),
  contentType: 'image/png',
  extension: 'png',
);

Message replyMsg(String id) => Message(
  id: id,
  conversationId: 'c1',
  senderId: 'u2',
  body: 'q',
  createdAt: DateTime.now(),
);

void main() {
  late Directory tempDir;
  late DeviceFilesFake files;
  late HeldImageChat chat;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync();
    files = DeviceFilesFake(onDisk: true, root: tempDir.path);
    chat = HeldImageChat();
  });

  tearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets(
    'one photo offline: waits as a pending bubble with the clock, nothing stored; back online it is sent once',
    (WidgetTester t) async {
      final c = await start(t, chat, files);
      final controller = c.read(sendQueueProvider.notifier);

      controller.enqueuePhotos('c1', [img('p1')]);
      await hop(t);

      final pending = c.read(sendQueueProvider)['c1'] ?? const <Message>[];
      expect(pending.length, 1);
      final id = pending.first.id;
      expect(id, isNotEmpty);
      expect(
        chat.asked.single.image.id,
        id,
        reason: 'the stored row gets the bubble id',
      );
      expect(pending.first.sending, true);
      expect(pending.first.localImage, isNotNull);
      expect(pending.first.localImage, img('p1').bytes);

      expect(chat.asked.length, 1);
      expect(kept(files).length, 1);

      chat.fail(0, offline);
      await t.pump(const Duration(seconds: 1));
      await hop(t);

      expect(chat.asked.length, 2);
      expect(chat.asked[1].image.id, id);
      expect(ids(c), [id]);
      expect(kept(files).length, 1);

      chat.ok(1);
      await hop(t);

      expect(c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);
      expect(kept(files).isEmpty, true);

      await t.pump(const Duration(seconds: 30));
      await hop(t);
      expect(chat.asked.length, 2);
    },
  );

  testWidgets(
    'album of three offline: three pending, caption and reply only on photo one, sent in order',
    (WidgetTester t) async {
      final c = await start(t, chat, files);
      final controller = c.read(sendQueueProvider.notifier);

      controller.enqueuePhotos(
        'c1',
        [img('p1'), img('p2'), img('p3')],
        body: 'trip',
        replyTo: replyMsg('m9'),
      );
      await hop(t);

      final pending = c.read(sendQueueProvider)['c1'] ?? const <Message>[];
      final all = ids(c);
      expect(all.toSet().length, 3);
      expect(pending.map((m) => m.localImage).toList(), [
        img('p1').bytes,
        img('p2').bytes,
        img('p3').bytes,
      ]);
      expect(pending.every((m) => m.sending), true);
      expect(pending.every((m) => m.photoGroup != null), true);
      expect(kept(files).length, 3);

      expect(chat.asked.length, 1);
      expect(chat.asked[0].image.id, all[0]);
      expect(chat.asked[0].image.bytes, img('p1').bytes);
      expect(chat.asked[0].body, 'trip');
      expect(chat.asked[0].replyTo, 'm9');

      chat.fail(0, offline);
      await t.pump(const Duration(seconds: 1));
      await hop(t);

      expect(chat.asked.length, 2);
      expect(chat.asked[1].image.id, all[0]);
      expect(chat.asked[1].body, 'trip');

      chat.ok(1);
      await hop(t);

      expect(chat.asked.length, 3);
      expect(chat.asked[2].image.id, all[1]);
      expect(chat.asked[2].body, '');
      expect(chat.asked[2].replyTo, null);

      chat.ok(2);
      await hop(t);

      expect(chat.asked.length, 4);
      expect(chat.asked[3].image.id, all[2]);
      expect(chat.asked[3].body, '');
      expect(chat.asked[3].replyTo, null);

      chat.ok(3);
      await hop(t);

      expect(c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);
      expect(kept(files).isEmpty, true);
    },
  );

  testWidgets(
    'a refused photo stops that conversation queue and deletes the kept files; the caption is not sent again',
    (WidgetTester t) async {
      final c = await start(t, chat, files);
      final controller = c.read(sendQueueProvider.notifier);

      controller.enqueuePhotos(
        'c1',
        [img('p1'), img('p2'), img('p3')],
        body: 'trip',
        replyTo: replyMsg('m9'),
      );
      await hop(t);

      expect(chat.asked.length, 1);
      chat.ok(0);
      await hop(t);

      expect(chat.asked.length, 2);
      expect(chat.asked[1].image.bytes, img('p2').bytes);

      chat.fail(1, refusal);
      await hop(t);

      await t.pump(const Duration(seconds: 30));
      await hop(t);

      expect(chat.asked.length, 2);
      expect(c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);
      expect(kept(files).isEmpty, true);
    },
  );

  testWidgets(
    'a photo the server denies (a taken id) is a refusal: stops the queue, deletes the kept files, is never retried or sent',
    (WidgetTester t) async {
      final c = await start(t, chat, files);
      final controller = c.read(sendQueueProvider.notifier);

      controller.enqueuePhotos(
        'c1',
        [img('p1'), img('p2')],
        body: 'trip',
        replyTo: replyMsg('m9'),
      );
      await hop(t);

      expect(chat.asked.length, 1);
      chat.fail(0, const DeniedFailure());
      await hop(t);

      await t.pump(const Duration(seconds: 30));
      await hop(t);

      expect(chat.asked.length, 1, reason: 'no retry and no second photo');
      expect(c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);
      expect(kept(files).isEmpty, true);
    },
  );
}
