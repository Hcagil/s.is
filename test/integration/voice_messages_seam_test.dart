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
import 'package:sis/features/chat/domain/voice.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/reach.dart';
import '../support/video_fakes.dart';

/// The seam SendQueueController.enqueueFile <-> SupabaseChatFileRepository
/// <-> the attachments bucket and messages on the local stack, wired as
/// main.dart wires it; the recording is a real m4a-named file on disk, as the
/// recorder leaves it. A sent voice reaches the other member with its length,
/// waveform and transcript, and the chat list shows the voice line; a
/// non-member reads none of it and cannot send one. Uses the file seam's
/// seeded accounts in its own group.
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

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('sis-voice-seam');
    sanaClient = await _signedIn('fl-sana@integration.test');
    theoClient = await _signedIn('fl-theo@integration.test');
    umaClient = await _signedIn('fl-uma@integration.test');
    sanaId = sanaClient.auth.currentUser!.id;
    theoId = theoClient.auth.currentUser!.id;
    final sanaChat = SupabaseChatRepository(sanaClient);
    final title = 'voice seam ${stamp()}';
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

  test('a voice sent through the queue reaches the other member with its metadata and transcript; a non-member gets neither and cannot send one', () async {
    final m4a = bytesOf(30000, 3);
    const wave = '0123456789abcdef0123456789abcdef01234567';
    final id = randomMessageId();
    final voiceFile = File('${tmp.path}/$id/voice-20261009-101500.m4a')
      ..createSync(recursive: true)
      ..writeAsBytesSync(m4a);

    final c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
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
    final file = PickedFile(
      id: id,
      path: voiceFile.path,
      name: 'voice-20261009-101500.m4a',
      mime: voiceMime,
      size: m4a.length,
      durationMs: 4200,
      waveform: wave,
      transcript: 'see you at nine',
    );
    c.read(sendQueueProvider.notifier).enqueueFile(club, file);
    await until(
      () => (c.read(sendQueueProvider)[club] ?? const <Message>[]).isEmpty,
      'the queue to send the voice',
    );

    final r = await SupabaseChatRepository(theoClient).messages(club);
    final theirs = (r as Ok<List<Message>>).value.singleWhere(
      (m) => m.id == id,
    );
    expect(theirs.senderId, sanaId);
    expect(theirs.file?.isVoice, isTrue);
    expect(theirs.file!.mime, voiceMime);
    expect(theirs.file!.durationMs, 4200);
    expect(theirs.file!.waveform, wave);
    expect(theirs.file!.transcript, 'see you at nine');
    expect(theirs.body, '');
    expect(previewText(theirs), voicePreview);

    final path = theirs.attachmentPath!;
    final bucket = theoClient.storage.from('attachments');
    expect(await bucket.download(path), m4a, reason: 'theo gets the voice');

    final outsider = umaClient.storage.from('attachments');
    await expectLater(outsider.download(path), throwsA(anything));

    final send = await SupabaseChatFileRepository(umaClient).send(
      club,
      PickedFile(
        id: randomMessageId(),
        path: voiceFile.path,
        name: 'x.m4a',
        mime: voiceMime,
        size: m4a.length,
        durationMs: 4200,
        waveform: wave,
        transcript: 'see you at nine',
      ),
    );
    expect(send, isA<Err<Message>>());
    expect((send as Err<Message>).failure, isA<DeniedFailure>());

    final convs = await SupabaseChatRepository(theoClient).conversations();
    final conv = (convs as Ok<List<Conversation>>).value.singleWhere(
      (x) => x.id == club,
    );
    expect(
      conv.lastMessage,
      voicePreview,
      reason: 'the chat list shows the voice line',
    );
  });
}
