import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/attachment.dart';

import '../../support/held_image_chat.dart';
import '../../support/held_send_chat.dart';
import '../../support/file_fakes.dart';
import '../../support/memory_send_queue_store.dart';
import '../../support/video_fakes.dart';

class _Session extends SessionController {
  _Session(this.initial);
  final SessionState initial;
  @override
  Future<SessionState> build() async => initial;
  void set(SessionState s) => state = AsyncData(s);
}

Future<void> hop(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    for (var j = 0; j < 5; j++) {
      await t.pump(const Duration(milliseconds: 5));
    }
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
  for (var j = 0; j < 5; j++) {
    await t.pump(const Duration(milliseconds: 5));
  }
}

PickedImage img(String id) => PickedImage(
  bytes: Uint8List.fromList([1, 2, 3, id.codeUnitAt(1)]),
  contentType: 'image/png',
  extension: 'png',
);

late Directory dir;
late MemorySendQueueStore store;

List<File> kept() => dir.existsSync()
    ? dir.listSync(recursive: true).whereType<File>().toList()
    : [];

/// One run of the app: its own server fake, the same phone folder and store.
Future<({ProviderContainer c, HeldImageChat chat})> run(WidgetTester t) async {
  final chat = HeldImageChat();
  final c = ProviderContainer.test(
    overrides: [
      ...videoOverrides(store: store),
      chatRepositoryProvider.overrideWithValue(chat),
      deviceFilesProvider.overrideWithValue(
        DeviceFilesFake(onDisk: true, root: dir.path),
      ),
      sessionControllerProvider.overrideWith(() => _Session(const Allowed(me))),
    ],
  );
  c.listen(sessionControllerProvider, (_, _) {});
  c.listen(sendQueueProvider, (_, _) {});
  await hop(t);
  return (c: c, chat: chat);
}

List<String> ids(ProviderContainer c) => [
  for (final m in c.read(sendQueueProvider)['c1'] ?? const <Message>[]) m.id,
];

void main() {
  setUp(() {
    store = MemorySendQueueStore();
    dir = Directory.systemTemp.createTempSync('photo_restore');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets(
    'killed with two photos waiting: the next start brings both back from the kept files and sends them in order, each once',
    (WidgetTester t) async {
      final a = await run(t);
      final q = a.c.read(sendQueueProvider.notifier);
      q.enqueuePhotos('c1', [img('p1'), img('p2')]);
      await hop(t);
      final idsA = ids(a.c);
      expect(idsA.length, 2);
      expect(kept().length, 2);
      a.c.dispose();

      final b = await run(t);
      final idsB = ids(b.c);
      expect(idsB, idsA);
      final pending = b.c.read(sendQueueProvider)['c1'] ?? const <Message>[];
      expect(pending.length, 2);
      expect(pending.every((m) => m.sending), isTrue);
      expect(pending.map((m) => m.localImage).toList(), [
        img('p1').bytes,
        img('p2').bytes,
      ]);

      expect(b.chat.asked.length, 1);
      expect(b.chat.asked[0].image.id, idsA[0]);
      expect(b.chat.asked[0].image.bytes, img('p1').bytes);
      b.chat.ok(0);
      await hop(t);

      expect(b.chat.asked.length, 2);
      expect(b.chat.asked[1].image.id, idsA[1]);
      expect(b.chat.asked[1].image.bytes, img('p2').bytes);
      b.chat.ok(1);
      await hop(t);

      expect(b.c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);
      expect(kept().isEmpty, true);
      await t.pump(const Duration(seconds: 30));
      await hop(t);
      expect(b.chat.asked.length, 2);
    },
  );

  testWidgets(
    'killed with two photos waiting and one kept file gone: only the other comes back, the gone one is dropped',
    (WidgetTester t) async {
      final a = await run(t);
      final q = a.c.read(sendQueueProvider.notifier);
      q.enqueuePhotos('c1', [img('p1'), img('p2')]);
      await hop(t);
      final idsA = ids(a.c);
      expect(idsA.length, 2);
      expect(kept().length, 2);
      a.c.dispose();

      // delete the file that corresponds to img('p2')
      for (final f in kept()) {
        if (listEquals(f.readAsBytesSync(), img('p2').bytes)) {
          f.deleteSync();
          break;
        }
      }

      final b = await run(t);
      final idsB = ids(b.c);
      expect(idsB, [idsA[0]]);
      final pending = b.c.read(sendQueueProvider)['c1'] ?? const <Message>[];
      expect(pending.length, 1);
      expect(pending.first.id, idsA[0]);

      expect(b.chat.asked.length, 1);
      expect(b.chat.asked[0].image.id, idsA[0]);
      expect(b.chat.asked[0].image.bytes, img('p1').bytes);
      b.chat.ok(0);
      await hop(t);

      expect(b.c.read(sendQueueProvider)['c1'] ?? const <Message>[], isEmpty);
      await t.pump(const Duration(seconds: 30));
      await hop(t);
      expect(b.chat.asked.length, 1);
    },
  );
}
