@Tags(['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/application/chat_drafts.dart';
import 'package:sis/features/chat/data/supabase_chat_file_repository.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/video.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/reach.dart';
import '../support/video_fakes.dart';

/// The seam SendQueueController.enqueueVideo <-> SupabaseChatFileRepository
/// <-> the attachments bucket and messages on the local stack, wired as
/// main.dart wires it; only the phone's shrinker is a stand-in that leaves a
/// real mp4 and thumbnail on disk. A sent video reaches the other member with
/// its length and its thumbnail at `<path>.t`; a non-member reads neither and
/// cannot send one. Uses the file seam's seeded accounts in its own group.
/// Run with --concurrency=1, TZ=JST-9.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';

Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  try {
    await client.auth.signInWithPassword(email: email, password: _password);
  } on AuthException {
    await client.auth.signUp(email: email, password: _password);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

class _As extends SessionController {
  _As(this.id);
  final String id;
  @override
  Future<SessionState> build() async =>
      Allowed(Member(userId: id, displayName: id));
}

/// Shrinks on disk as the real one does: the mp4 and the jpeg stay.
class _DiskVideos extends DeviceVideosFake {
  _DiskVideos(this.root, this.mp4);
  final String root;
  final Uint8List mp4;

  @override
  Future<Result<PickedFile>> compress(
    VideoSource source, {
    void Function(double fraction)? onProgress,
  }) async {
    final out = File('$root/${source.id}.mp4')..writeAsBytesSync(mp4);
    return Ok(
      PickedFile(
        id: source.id,
        path: out.path,
        name: videoFileName(source.name),
        mime: videoMime,
        size: mp4.length,
        durationMs: source.durationMs,
        thumbPath: source.thumbPath,
      ),
    );
  }
}

void main() {
  late SupabaseClient sanaClient, theoClient, umaClient;
  late String sanaId, theoId;
  late String club;
  late Directory tmp;

  String stamp() => '${DateTime.now().microsecondsSinceEpoch}';
  Uint8List bytesOf(int n, int seed) =>
      Uint8List.fromList([for (var i = 0; i < n; i++) (i * 17 + seed) & 0xff]);

  Future<void> until(bool Function() done, String what) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  VideoSource picked(Uint8List thumb) {
    final id = randomMessageId();
    final dir = Directory('${tmp.path}/picked/$id')
      ..createSync(recursive: true);
    final src = File('${dir.path}/Beach day.mov')..writeAsBytesSync([1, 2, 3]);
    final jpg = File('${dir.path}/thumb.jpg')..writeAsBytesSync(thumb);
    return VideoSource(
      id: id,
      path: src.path,
      name: 'Beach day.mov',
      size: 3,
      durationMs: 41000,
      width: 1920,
      height: 1080,
      thumbPath: jpg.path,
    );
  }

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('sis-video-seam');
    sanaClient = await _signedIn('fl-sana@integration.test');
    theoClient = await _signedIn('fl-theo@integration.test');
    umaClient = await _signedIn('fl-uma@integration.test');
    sanaId = sanaClient.auth.currentUser!.id;
    theoId = theoClient.auth.currentUser!.id;
    final sanaChat = SupabaseChatRepository(sanaClient);
    final title = 'video seam ${stamp()}';
    var r = await sanaChat.startGroupConversation(
      title: title,
      memberIds: [theoId],
    );
    if (r is Err<String>) {
      await findByTag(sanaClient, [theoClient]);
      r = await sanaChat.startGroupConversation(
        title: title,
        memberIds: [theoId],
      );
    }
    club = (r as Ok<String>).value;
  });

  tearDownAll(() async {
    for (final c in [sanaClient, theoClient, umaClient]) {
      await c.removeAllChannels();
      await c.dispose();
    }
    tmp.deleteSync(recursive: true);
  });

  test('a video sent through the queue reaches the other member with its '
      'length, and its thumbnail is beside it; a non-member gets neither '
      'and cannot send one', () async {
    final mp4 = bytesOf(90000, 1);
    final thumb = bytesOf(4000, 2);
    final c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(videos: _DiskVideos(tmp.path, mp4)),
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(sanaClient),
        ),
        chatFileRepositoryProvider.overrideWithValue(
          SupabaseChatFileRepository(sanaClient),
        ),
        sessionControllerProvider.overrideWith(() => _As(sanaId)),
      ],
    );
    addTearDown(c.dispose);
    await settled(c);
    c.listen(sendQueueProvider, (_, _) {});
    final source = picked(thumb);
    c.read(sendQueueProvider.notifier).enqueueVideo(club, source);
    await until(
      () => (c.read(sendQueueProvider)[club] ?? const <Message>[]).isEmpty,
      'the queue to send the video',
    );

    final r = await SupabaseChatRepository(theoClient).messages(club);
    final theirs = (r as Ok<List<Message>>).value.singleWhere(
      (m) => m.id == source.id,
    );
    expect(theirs.senderId, sanaId);
    expect(theirs.file?.isVideo, isTrue);
    expect(theirs.file!.durationMs, 41000);
    expect(theirs.file!.name, 'Beach day.mp4');
    expect(theirs.file!.mime, videoMime);
    expect(previewText(theirs), videoPreview);

    final path = theirs.attachmentPath!;
    final bucket = theoClient.storage.from('attachments');
    expect(await bucket.download(path), mp4, reason: 'theo gets the video');
    expect(
      await bucket.download('$path.t'),
      thumb,
      reason: 'and its thumbnail at <path>.t',
    );

    final outsider = umaClient.storage.from('attachments');
    await expectLater(outsider.download('$path.t'), throwsA(anything));
    await expectLater(outsider.download(path), throwsA(anything));

    final send = await SupabaseChatFileRepository(umaClient).send(
      club,
      PickedFile(
        id: randomMessageId(),
        path: '${tmp.path}/${source.id}.mp4',
        name: 'Intrude.mp4',
        mime: videoMime,
        size: mp4.length,
        durationMs: 41000,
        thumbPath: source.thumbPath,
      ),
    );
    expect(send, isA<Err<Message>>());
    expect((send as Err<Message>).failure, isA<DeniedFailure>());
  });
}
