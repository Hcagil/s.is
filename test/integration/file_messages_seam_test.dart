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
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/fakes.dart';
import '../support/file_fakes.dart';
import '../support/reach.dart';

/// The seam SendQueueController.enqueueFile / FileDownloads.start <->
/// SupabaseChatFileRepository <-> the attachments bucket and messages on the
/// local stack, wired as main.dart wires it (chatRepositoryProvider and
/// chatFileRepositoryProvider overridden with the Supabase repositories; only
/// the phone's file chooser and folder are a stand-in, a real temporary
/// folder). A sent file reaches the other member with its name, type and
/// size; the object is stored as application/octet-stream; a member
/// downloads the same bytes; a non-member is refused; a byte count that
/// differs from the promised size leaves nothing behind. Run with
/// --concurrency=1, TZ=JST-9.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _password = 'integration-password';
const _unavailable = 'This file is not available.';

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
  late String sanaId, theoId, umaId;
  late String club;
  late Directory tmp;

  String stamp() => '${DateTime.now().microsecondsSinceEpoch}';

  /// A container wired as main.dart wires the file seam, for [client].
  Future<ProviderContainer> app(
    SupabaseClient client,
    String id,
    DeviceFilesFake devices,
  ) async {
    final c = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(
          SupabaseChatRepository(client),
        ),
        chatFileRepositoryProvider.overrideWithValue(
          SupabaseChatFileRepository(client),
        ),
        deviceFilesProvider.overrideWithValue(devices),
        sessionControllerProvider.overrideWith(() => _As(id)),
      ],
    );
    addTearDown(c.dispose);
    await settled(c);
    c.listen(sendQueueProvider, (_, _) {});
    c.listen(fileDownloadsProvider, (_, _) {});
    return c;
  }

  /// A file the member picked, written for real where the chooser copies it.
  PickedFile pickedOnDisk(String name, String mime, Uint8List bytes) {
    final id = randomMessageId();
    final dir = Directory('${tmp.path}/picked/$id')
      ..createSync(recursive: true);
    final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    return PickedFile(
      id: id,
      path: f.path,
      name: name,
      mime: mime,
      size: bytes.length,
    );
  }

  Future<List<Message>> stored(SupabaseClient as) async {
    final r = await SupabaseChatRepository(as).messages(club);
    expect(r, isA<Ok<List<Message>>>(), reason: '$r');
    return (r as Ok<List<Message>>).value;
  }

  Future<void> until(bool Function() done, String what) async {
    final end = DateTime.now().add(const Duration(seconds: 20));
    while (!done()) {
      if (DateTime.now().isAfter(end)) fail('timed out waiting for $what');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  Uint8List bytesOf(int n, int seed) =>
      Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + seed) & 0xff]);

  /// Sends [file] from sana through the queue and returns theo's stored copy.
  Future<Message> sendThroughQueue(PickedFile file) async {
    final sana = await app(sanaClient, sanaId, DeviceFilesFake());
    final pending = sana
        .read(sendQueueProvider.notifier)
        .enqueueFile(club, file);
    expect(pending.id, file.id);
    expect(pending.sending, isTrue);
    await until(
      () => (sana.read(sendQueueProvider)[club] ?? const <Message>[]).isEmpty,
      'the queue to send the file',
    );
    final theirs = (await stored(theoClient))
        .where((m) => m.id == file.id)
        .toList();
    expect(theirs, hasLength(1), reason: 'theo reads the stored file message');
    return theirs.single;
  }

  setUpAll(() async {
    tmp = Directory.systemTemp.createTempSync('sis-files-seam');
    sanaClient = await _signedIn('fl-sana@integration.test');
    theoClient = await _signedIn('fl-theo@integration.test');
    umaClient = await _signedIn('fl-uma@integration.test');
    sanaId = sanaClient.auth.currentUser!.id;
    theoId = theoClient.auth.currentUser!.id;
    umaId = umaClient.auth.currentUser!.id;
    final sanaChat = SupabaseChatRepository(sanaClient);
    final title = 'files seam ${stamp()}';
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

  tearDown(() async {
    for (final c in [sanaClient, theoClient, umaClient]) {
      await c.removeAllChannels();
    }
  });

  tearDownAll(() async {
    for (final c in [sanaClient, theoClient, umaClient]) {
      await c.dispose();
    }
    tmp.deleteSync(recursive: true);
  });

  test('a file sent through the queue reaches the other member with its '
      'name, type and size, stored as octet-stream', () async {
    final bytes = bytesOf(70000, 1);
    final file = pickedOnDisk(
      'Cabin booking ${stamp()}.pdf',
      'application/pdf',
      bytes,
    );
    final theirs = await sendThroughQueue(file);
    expect(theirs.senderId, sanaId);
    expect(theirs.body, '');
    expect(theirs.file, isNotNull);
    expect(theirs.file!.name, file.name);
    expect(theirs.file!.mime, 'application/pdf');
    expect(theirs.file!.size, bytes.length);
    expect(theirs.attachmentPath, isNotNull);
    expect(previewText(theirs), '\u{1F4CE} ${file.name}');

    final path = theirs.attachmentPath!;
    final slash = path.lastIndexOf('/');
    final listed = await theoClient.storage
        .from('attachments')
        .list(path: path.substring(0, slash));
    final object = listed.singleWhere(
      (o) => o.name == path.substring(slash + 1),
    );
    expect(
      object.metadata?['mimetype'],
      'application/octet-stream',
      reason: 'the bucket holds every non-photo file as octet-stream',
    );
  });

  test('a member downloads the same bytes through FileDownloads', () async {
    final bytes = bytesOf(120000, 2);
    final file = pickedOnDisk('Menu ${stamp()}.xlsx', 'application/zip', bytes);
    final theirs = await sendThroughQueue(file);

    final devices = DeviceFilesFake(root: '${tmp.path}/theo', onDisk: true);
    final theo = await app(theoClient, theoId, devices);
    final key = (id: theirs.id, name: theirs.file!.name);
    theo.listen(storedFileProvider(key), (_, _) {});
    expect(await theo.read(storedFileProvider(key).future), isNull);

    final failure = await theo
        .read(fileDownloadsProvider.notifier)
        .start(theirs);
    expect(failure, isNull, reason: '$failure');
    expect(theo.read(fileDownloadsProvider), isNot(contains(theirs.id)));
    final kept = await theo.read(storedFileProvider(key).future);
    expect(kept, isNotNull, reason: 'the kept copy is found after download');
    expect(File(kept!).readAsBytesSync(), bytes);
  });

  test('a non-member is refused: no download, no file left, no send', () async {
    final bytes = bytesOf(5000, 3);
    final file = pickedOnDisk('Secret ${stamp()}.txt', 'text/plain', bytes);
    final theirs = await sendThroughQueue(file);

    final dest = '${tmp.path}/uma-${stamp()}.txt';
    final r = await SupabaseChatFileRepository(umaClient)
        .download(theirs.attachmentPath!, dest, expectedSize: bytes.length);
    expect(r, isA<Err<void>>());
    final f = (r as Err<void>).failure;
    expect(f, isA<NetworkFailure>());
    expect((f as NetworkFailure).message, _unavailable);
    expect(File(dest).existsSync(), isFalse);

    final send = await SupabaseChatFileRepository(umaClient)
        .send(club, pickedOnDisk('Intrude.txt', 'text/plain', bytes));
    expect(send, isA<Err<Message>>());
    expect((send as Err<Message>).failure, isA<DeniedFailure>());
    expect(umaId, isNot(sanaId));
  });

  test('a byte count different from the promised size is deleted and is '
      'not available', () async {
    final bytes = bytesOf(9000, 4);
    final file = pickedOnDisk(
      'Size ${stamp()}.bin',
      'application/x-thing',
      bytes,
    );
    final theirs = await sendThroughQueue(file);

    final dest = '${tmp.path}/theo-size-${stamp()}.bin';
    final r = await SupabaseChatFileRepository(theoClient)
        .download(theirs.attachmentPath!, dest, expectedSize: bytes.length + 1);
    expect(r, isA<Err<void>>());
    final f = (r as Err<void>).failure;
    expect((f as NetworkFailure).message, _unavailable);
    expect(File(dest).existsSync(), isFalse, reason: 'nothing left behind');

    final ok = await SupabaseChatFileRepository(theoClient)
        .download(theirs.attachmentPath!, dest, expectedSize: bytes.length);
    expect(ok, isA<Ok<void>>(), reason: 'control: the right size downloads');
    expect(File(dest).readAsBytesSync(), bytes);
  });

  test('sending the same file again (a retry after a lost answer) is '
      'harmless: one message', () async {
    final bytes = bytesOf(3000, 5);
    final file = pickedOnDisk('Retry ${stamp()}.txt', 'text/plain', bytes);
    final repo = SupabaseChatFileRepository(sanaClient);
    final first = await repo.send(club, file);
    expect(first, isA<Ok<Message>>(), reason: '$first');
    final again = await repo.send(club, file);
    expect(again, isA<Ok<Message>>(), reason: '$again');
    final rows = (await stored(theoClient)).where((m) => m.id == file.id);
    expect(rows, hasLength(1));
    expect(rows.single.file!.size, bytes.length);
  });
}
