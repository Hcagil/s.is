@Tags(['integration'])
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart' as img;
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';

/// The small notification picture of a photo, `<attachment_path>.t`, against
/// the real attachments bucket and its policies (Update 2 step 12):
/// - sendImage uploads it right after the photo: a JPEG at most 480 px wide
///   and 65536 bytes; when no picture can be made the photo still sends.
/// - forward copies it beside the copy, so the other chat's members (and only
///   they) read it; a photo without one still forwards.
/// - deleteForEveryone removes it with the photo.
/// Uses the file seam's seeded accounts (fl-sana/fl-theo/fl-uma) in its own
/// groups. Run with --concurrency=1, TZ=JST-9.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
Future<SupabaseClient> _signedIn(String email) async {
  final client = SupabaseClient(
    _url,
    _key,
    authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
  );
  await setLocalTestPassword(_url, email, localTestPassword);
  try {
    await client.auth.signInWithPassword(
      email: email,
      password: localTestPassword,
    );
  } on AuthException {
    await client.auth.signUp(email: email, password: localTestPassword);
  }
  expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  expect(await client.rpc('activate_session'), isTrue);
  return client;
}

/// A real, hard-to-compress picture of [w] x [h] pixels.
Uint8List _noisePng(int w, int h) {
  final rnd = Random(7);
  final px = Uint8List(w * h * 4);
  for (var i = 0; i < px.length; i++) {
    px[i] = (i % 4 == 3) ? 255 : rnd.nextInt(256);
  }
  return img.encodePng(
    img.Image.fromBytes(
      width: w,
      height: h,
      bytes: px.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    ),
  );
}

void main() {
  late SupabaseClient sana, theo, uma, service;
  late String club, other;
  late Uint8List photo;

  String stamp() => '${DateTime.now().microsecondsSinceEpoch}';

  /// Whether [path] exists in the bucket at all (the service role sees everything).
  Future<bool> stored(String path) async {
    final slash = path.lastIndexOf('/');
    final list = await service.storage
        .from('attachments')
        .list(
          path: path.substring(0, slash),
          searchOptions: SearchOptions(search: path.substring(slash + 1)),
        );
    return list.any((o) => o.name == path.substring(slash + 1));
  }

  Future<Message> theirs(SupabaseClient as, String conv, String id) async {
    final r = await SupabaseChatRepository(as).messages(conv);
    return (r as Ok<List<Message>>).value.singleWhere((m) => m.id == id);
  }

  Future<String> group(
    SupabaseClient owner,
    SupabaseClient member,
    String title,
  ) async {
    final repo = SupabaseChatRepository(owner);
    final id = member.auth.currentUser!.id;
    var r = await repo.startGroupConversation(title: title, memberIds: [id]);
    if (r is Err<String>) {
      await findByTag(owner, [member]);
      r = await repo.startGroupConversation(title: title, memberIds: [id]);
    }
    return (r as Ok<String>).value;
  }

  setUpAll(() async {
    sana = await _signedIn('fl-sana@integration.test');
    theo = await _signedIn('fl-theo@integration.test');
    uma = await _signedIn('fl-uma@integration.test');
    service = SupabaseClient(_url, serviceKey());
    club = await group(sana, theo, 'picture seam ${stamp()}');
    // theo and uma: a chat sana is not in, for the forward.
    other = await group(theo, uma, 'picture seam other ${stamp()}');
    photo = _noisePng(1200, 800);
  });

  tearDownAll(() async {
    for (final c in [sana, theo, uma, service]) {
      await c.removeAllChannels();
      await c.dispose();
    }
  });

  Future<Message> send(Uint8List bytes, {String type = 'image/png'}) async {
    final r = await SupabaseChatRepository(sana).sendImage(
      conversationId: club,
      image: PickedImage(
        bytes: bytes,
        contentType: type,
        extension: type == 'image/png' ? 'png' : 'jpg',
      ),
    );
    expect(r, isA<Ok<Message>>(), reason: 'sendImage: $r');
    return (r as Ok<Message>).value;
  }

  test('sendImage puts a JPEG of at most 480 px and 64 KiB beside the photo, '
      'readable by the chat only', () async {
    final sent = await send(photo);
    final path = (await theirs(theo, club, sent.id)).attachmentPath!;
    final bucket = theo.storage.from('attachments');
    expect(await bucket.download(path), photo, reason: 'the photo itself');
    final small = await bucket.download('$path.t');
    expect(small.sublist(0, 3), [0xff, 0xd8, 0xff], reason: 'a JPEG');
    expect(small.length, lessThanOrEqualTo(65536));
    final decoded = img.decodeJpg(small);
    expect(decoded.width, 480, reason: 'shrunk to 480 px wide');
    expect(decoded.height, 320, reason: 'the aspect ratio is kept');
    await expectLater(
      uma.storage.from('attachments').download('$path.t'),
      throwsA(anything),
      reason: 'a non-member cannot read the picture',
    );
  });

  test('a photo no picture can be made of still sends, without a .t', () async {
    // Not a decodable picture: the shrinker gives up.
    final junk = Uint8List.fromList(List.filled(3000, 0x41));
    final sent = await send(junk, type: 'image/jpeg');
    final path = (await theirs(theo, club, sent.id)).attachmentPath!;
    expect(await stored(path), isTrue, reason: 'the photo is stored');
    expect(await stored('$path.t'), isFalse, reason: 'no picture');
  });

  test(
    'theo forwards sana\'s photo into a chat sana is not in: the copy has its '
    'own picture, which only that chat reads',
    () async {
      final sent = await send(photo);
      final original = await theirs(theo, club, sent.id);
      final r = await SupabaseChatRepository(theo).forward(original, [other]);
      expect(r, isA<Ok<void>>(), reason: 'forward: $r');
      final copies =
          ((await SupabaseChatRepository(uma).messages(other))
                  as Ok<List<Message>>)
              .value
              .where((m) => m.forwarded && m.attachmentPath != null)
              .toList();
      expect(copies, isNotEmpty, reason: 'uma sees the forwarded photo');
      final copy = copies.last.attachmentPath!;
      expect(copy, isNot(original.attachmentPath));
      final small = await theo.storage
          .from('attachments')
          .download('${original.attachmentPath}.t');
      expect(
        await uma.storage.from('attachments').download('$copy.t'),
        small,
        reason: 'the copy\'s picture is the original\'s',
      );
      await expectLater(
        uma.storage
            .from('attachments')
            .download('${original.attachmentPath}.t'),
        throwsA(anything),
        reason: 'uma still cannot read the original chat\'s picture',
      );
    },
  );

  test('a photo without a picture still forwards', () async {
    final sent = await send(
      Uint8List.fromList(List.filled(3000, 0x42)),
      type: 'image/jpeg',
    );
    final original = await theirs(theo, club, sent.id);
    final before = ((await SupabaseChatRepository(
      uma,
    ).messages(other)) as Ok<List<Message>>).value.length;
    final r = await SupabaseChatRepository(theo).forward(original, [other]);
    expect(r, isA<Ok<void>>(), reason: 'forward: $r');
    final after = ((await SupabaseChatRepository(
      uma,
    ).messages(other)) as Ok<List<Message>>).value;
    expect(after.length, before + 1, reason: 'the copy arrived');
  });

  test('deleteForEveryone removes the picture with the photo', () async {
    final sent = await send(photo);
    final mine = await theirs(sana, club, sent.id);
    final path = mine.attachmentPath!;
    expect(await stored('$path.t'), isTrue, reason: 'fixture: a picture');
    final r = await SupabaseChatRepository(sana).deleteForEveryone(mine);
    expect(r, isA<Ok<void>>(), reason: 'delete: $r');
    expect(await stored(path), isFalse, reason: 'the photo is gone');
    expect(await stored('$path.t'), isFalse, reason: 'and its picture');
  });

  test('deleteForEveryone of a photo without a picture still works', () async {
    final sent = await send(
      Uint8List.fromList(List.filled(3000, 0x43)),
      type: 'image/jpeg',
    );
    final mine = await theirs(sana, club, sent.id);
    final r = await SupabaseChatRepository(sana).deleteForEveryone(mine);
    expect(r, isA<Ok<void>>(), reason: 'delete: $r');
    expect(await stored(mine.attachmentPath!), isFalse);
  });
}
