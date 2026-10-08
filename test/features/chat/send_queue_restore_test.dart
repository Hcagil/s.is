// Pending sends survive the app being killed (Update 2, 7b): the queue is
// saved by the real SharedPrefsSendQueueStore, files live on a real disk, and
// a second container (the restarted app) brings the sends back and resumes
// them. The video fake behaves as the real shrinker does on disk: success
// deletes the picked copy and leaves the shrunk mp4.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/data/shared_prefs_send_queue_store.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/video.dart';

import '../../support/file_fakes.dart';
import '../../support/held_send_chat.dart';
import '../../support/video_fakes.dart';

class _Session extends SessionController {
  _Session(this.initial);
  final SessionState initial;
  @override
  Future<SessionState> build() async => initial;
  void set(SessionState s) => state = AsyncData(s);
}

/// Shrinks on disk like the real one: the source copy goes, the mp4 stays.
class _DiskVideos extends DeviceVideosFake {
  _DiskVideos(this.root);
  final String root;

  @override
  void compressOk(int i, {int size = 8388608}) {
    final src = compressions[i].source;
    final out = '$root/${src.id}.mp4';
    File(out).writeAsStringSync('mp4');
    File(src.path).deleteSync();
    compressions[i].answer.complete(
      Ok(
        PickedFile(
          id: src.id,
          path: out,
          name: videoFileName(src.name),
          mime: videoMime,
          size: size,
          durationMs: src.durationMs,
          thumbPath: src.thumbPath,
        ),
      ),
    );
  }
}

void main() {
  late Directory dir;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('restore');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// Frames plus real time for the disk and the prefs channel.
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

  String onDisk(String name) {
    final f = File('${dir.path}/$name')..writeAsStringSync('x');
    return f.path;
  }

  PickedFile pdf(String id) => PickedFile(
    id: id,
    path: onDisk('$id.pdf'),
    name: 'Cabin booking.pdf',
    mime: 'application/pdf',
    size: 2516582,
  );

  VideoSource clip(String id) => VideoSource(
    id: id,
    path: onDisk('$id.mov'),
    name: 'Beach day.mov',
    size: 31457280,
    durationMs: 41000,
    width: 1920,
    height: 1080,
    thumbPath: onDisk('$id.jpg'),
  );

  /// One run of the app for [who], with its own server and phone fakes;
  /// [owner] mounts the eraser SisApp mounts.
  Future<
    ({
      ProviderContainer c,
      HeldSendChat chat,
      FileRepoFake files,
      _DiskVideos videos,
    })
  >
  run(WidgetTester t, {Member who = me, bool owner = false}) async {
    final chat = HeldSendChat();
    final files = FileRepoFake();
    final videos = _DiskVideos(dir.path);
    final c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(
          store: const SharedPrefsSendQueueStore(),
          videos: videos,
        ),
        chatRepositoryProvider.overrideWithValue(chat),
        chatFileRepositoryProvider.overrideWithValue(files),
        sessionControllerProvider.overrideWith(() => _Session(Allowed(who))),
      ],
    );
    c.listen(sessionControllerProvider, (_, _) {});
    if (owner) c.listen(sendQueueOwnerProvider, (_, _) {});
    c.listen(sendQueueProvider, (_, _) {});
    await hop(t);
    return (c: c, chat: chat, files: files, videos: videos);
  }

  List<String> pending(ProviderContainer c) => [
    for (final m in c.read(sendQueueProvider)['c1'] ?? const <Message>[]) m.id,
  ];

  Future<Set<String>> keys() async =>
      (await SharedPreferences.getInstance()).getKeys();

  testWidgets('killed with a text, a file and a video waiting: the next start '
      'shows all three in order and sends each, the video shrunk once', (
    t,
  ) async {
    final a = await run(t);
    final q = a.c.read(sendQueueProvider.notifier);
    final text = q.enqueue('c1', body: 'hello');
    q.enqueueFile('c1', pdf('f1'));
    q.enqueueVideo('c1', clip('v1'));
    await hop(t);
    expect(await keys(), contains('sis.sendqueue.u1'));
    a.c.dispose(); // the app is killed; nothing was answered

    final b = await run(t);
    expect(pending(b.c), [text.id, 'f1', 'v1']);
    expect(b.c.read(sendQueueProvider)['c1']!.every((m) => m.sending), isTrue);
    final v = b.c.read(sendQueueProvider)['c1']!.last;
    expect(v.file?.isVideo, isTrue, reason: 'the video bubble comes back');
    expect(v.file?.name, 'Beach day.mp4');

    expect(b.chat.asked.single.id, text.id);
    expect(b.chat.asked.single.body, 'hello');
    b.chat.ok(0);
    await hop(t);
    expect(b.files.sends.single.file.id, 'f1');
    b.files.sendOk(0);
    await hop(t);
    expect(b.videos.compressions.single.source.id, 'v1');
    b.videos.compressOk(0);
    await hop(t);
    expect(b.files.sends[1].file.id, 'v1');
    expect(b.files.sends[1].file.durationMs, 41000);
    b.files.sendOk(1);
    await hop(t);
    expect(pending(b.c), isEmpty);
    expect(await keys(), isNot(contains('sis.sendqueue.u1')));
    await t.pump(const Duration(seconds: 30));
  });

  testWidgets('killed after the video was shrunk, during its upload: the next '
      'start uploads the shrunk file without shrinking again', (t) async {
    final a = await run(t);
    a.c.read(sendQueueProvider.notifier).enqueueVideo('c1', clip('v1'));
    await hop(t);
    a.videos.compressOk(0); // the picked copy is gone from the disk now
    await hop(t);
    expect(a.files.sends.single.file.id, 'v1');
    a.c.dispose();

    final b = await run(t);
    expect(pending(b.c), ['v1'], reason: 'the video send was lost');
    expect(b.videos.compressions, isEmpty);
    expect(b.files.sends.single.file.path, '${dir.path}/v1.mp4');
    expect(b.files.sends.single.file.durationMs, 41000);
    b.files.sendOk(0);
    await hop(t);
    expect(pending(b.c), isEmpty);
    await t.pump(const Duration(seconds: 30));
  });

  testWidgets('a file deleted from the phone between runs is not brought '
      'back; the sends beside it still are', (t) async {
    final a = await run(t);
    final q = a.c.read(sendQueueProvider.notifier);
    final f = pdf('f1');
    q.enqueueFile('c1', f);
    final text = q.enqueue('c1', body: 'after');
    await hop(t);
    a.c.dispose();
    File(f.path).deleteSync();

    final b = await run(t);
    expect(pending(b.c), [text.id]);
    await t.pump(const Duration(seconds: 30));
  });

  testWidgets("another member on this phone never gets the first one's "
      'waiting sends', (t) async {
    final a = await run(t);
    a.c.read(sendQueueProvider.notifier).enqueue('c1', body: 'mine');
    await hop(t);
    a.c.dispose();

    final b = await run(
      t,
      who: const Member(userId: 'u9', displayName: 'Ece'),
    );
    expect(pending(b.c), isEmpty);
    expect(b.chat.asked, isEmpty);
    await t.pump(const Duration(seconds: 30));
  });

  for (final (name, ended) in [
    ('SignedOut', const SignedOut()),
    ('Denied', const Denied()),
  ]) {
    testWidgets('the session ending ($name) forgets the saved queue', (
      t,
    ) async {
      final a = await run(t, owner: true);
      a.c.read(sendQueueProvider.notifier).enqueue('c1', body: 'mine');
      await hop(t);
      expect(await keys(), contains('sis.sendqueue.u1'));
      (a.c.read(sessionControllerProvider.notifier) as _Session).set(ended);
      await hop(t);
      expect(
        (await keys()).where((k) => k.startsWith('sis.sendqueue.')),
        isEmpty,
      );
      await t.pump(const Duration(seconds: 30));
    });
  }
}
