@Tags(['integration'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:imcodec/imcodec.dart' as img;
import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/data/supabase_chat_repository.dart';
import 'package:sis/features/chat/domain/link_preview.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../support/reach.dart';
import '../support/service_key.dart';

/// Link cards across the real seam: the sender's [SupabaseChatRepository]
/// stores the card on the message and its picture in the private
/// `link-previews` bucket; another member's repository reads both back from
/// SIS alone. The website is a real local HTTP server that counts every hit:
/// the reader must never contact it (owner answer d).
///
/// Accounts priya, quinlan (members) and remy (not a member) are shared with
/// other suites; each run makes a new group. Run with --concurrency=1.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

SupabaseClient _client(String key) => SupabaseClient(
  _url,
  key,
  authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
);

Future<SupabaseClient> _signedIn(String email) async {
  await setLocalTestPassword(_url, email, localTestPassword);
  final client = _client(_key);
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

T _ok<T>(Result<T> r) {
  expect(r, isA<Ok<T>>(), reason: 'expected Ok: $r');
  return (r as Ok<T>).value;
}

/// A real, small JPEG: the bucket checks the mime type.
final Uint8List _jpeg = img.encodeJpg(img.Image(width: 8, height: 4));

void main() {
  late SupabaseClient priyaClient, quinlanClient, remyClient;
  late SupabaseChatRepository priya, quinlan, remy;
  late String club;
  late HttpServer site;
  var siteHits = 0;
  final cleanup = <String>[];

  String page(String path) => 'http://127.0.0.1:${site.port}/$path';

  LinkPreviewDraft draft(
    String url,
    String messageId, {
    Uint8List? image,
    String title = 'A page title',
  }) => LinkPreviewDraft(
    preview: LinkPreview(
      url: Uri.parse(url),
      title: title,
      description: 'What the page is about',
      site: 'Example',
      imagePath: image == null ? null : linkImagePath(club, messageId),
    ),
    image: image,
  );

  Future<Message> readBack(SupabaseChatRepository who, String id) async {
    final all = _ok(await who.messages(club));
    return all.singleWhere((m) => m.id == id);
  }

  setUpAll(() async {
    site = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    site.listen((r) {
      siteHits++;
      r.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<title>site</title>')
        ..close();
    });
    priyaClient = await _signedIn('priya@integration.test');
    quinlanClient = await _signedIn('quinlan@integration.test');
    remyClient = await _signedIn('remy@integration.test');
    priya = SupabaseChatRepository(priyaClient);
    quinlan = SupabaseChatRepository(quinlanClient);
    remy = SupabaseChatRepository(remyClient);
    final ids = [quinlanClient.auth.currentUser!.id];
    final title = 'link cards ${DateTime.now().microsecondsSinceEpoch}';
    var r = await priya.startGroupConversation(title: title, memberIds: ids);
    if (r is Err<String>) {
      await findByTag(priyaClient, [quinlanClient]);
      r = await priya.startGroupConversation(title: title, memberIds: ids);
    }
    club = _ok(r);
    cleanup.add(club);
  });

  tearDown(() async {
    for (final c in [priyaClient, quinlanClient, remyClient]) {
      await c.removeAllChannels();
    }
  });

  tearDownAll(() async {
    await site.close(force: true);
    final s = _client(serviceKey());
    for (final id in cleanup) {
      await s.from('conversations').delete().eq('id', id);
    }
  });

  test('a card with a picture: the reader gets both from SIS, the website '
      'is never contacted', () async {
    final id = randomMessageId();
    final url = page('article/one');
    final sent = _ok(
      await priya.send(
        id: id,
        conversationId: club,
        body: 'read $url',
        preview: draft(url, id, image: _jpeg),
      ),
    );
    expect(sent.linkPreview?.imagePath, linkImagePath(club, id));

    final got = await readBack(quinlan, id);
    final card = got.linkPreview;
    expect(card, isNotNull, reason: 'reads include link_preview');
    expect(card!.url, Uri.parse(url));
    expect(card.title, 'A page title');
    expect(card.description, 'What the page is about');
    expect(card.site, 'Example');
    expect(card.imagePath, linkImagePath(club, id));
    expect(_ok(await quinlan.linkImageBytes(card.imagePath!)), _jpeg);
    expect(siteHits, 0, reason: 'readers never contact the website');
  });

  test('the card also arrives live on the other member\'s feed', () async {
    final opened = _ok(await quinlan.incoming(club));
    final id = randomMessageId();
    final url = page('live');
    final live = opened
        .firstWhere((m) => m.id == id)
        .timeout(const Duration(seconds: 20));
    _ok(
      await priya.send(
        id: id,
        conversationId: club,
        body: url,
        preview: draft(url, id, title: 'Live card'),
      ),
    );
    final got = await live;
    expect(got.linkPreview?.title, 'Live card');
    expect(siteHits, 0);
  });

  test('a card without a picture is stored as text only', () async {
    final id = randomMessageId();
    final url = page('plain');
    _ok(
      await priya.send(
        id: id,
        conversationId: club,
        body: url,
        preview: draft(url, id),
      ),
    );
    final got = await readBack(quinlan, id);
    expect(got.linkPreview?.title, 'A page title');
    expect(got.linkPreview?.imagePath, isNull);
  });

  test('no card: the link stays a plain message (X, old messages)', () async {
    final id = randomMessageId();
    _ok(await priya.send(id: id, conversationId: club, body: page('x')));
    expect((await readBack(quinlan, id)).linkPreview, isNull);
  });

  test('a picture the bucket refuses: the card is sent without it', () async {
    final id = randomMessageId();
    final url = page('big');
    final tooBig = Uint8List(300000)..setAll(0, _jpeg);
    final sent = await priya.send(
      id: id,
      conversationId: club,
      body: url,
      preview: draft(url, id, image: tooBig),
    );
    expect(
      sent,
      isA<Ok<Message>>(),
      reason: 'a failed upload never fails the send',
    );
    final got = await readBack(quinlan, id);
    expect(got.linkPreview?.title, 'A page title');
    expect(got.linkPreview?.imagePath, isNull);
  });

  test(
    'a retried send whose picture is already there (409) keeps it',
    () async {
      final id = randomMessageId();
      final url = page('retry');
      await priyaClient.storage
          .from('link-previews')
          .uploadBinary(
            linkImagePath(club, id),
            _jpeg,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );
      _ok(
        await priya.send(
          id: id,
          conversationId: club,
          body: url,
          preview: draft(url, id, image: _jpeg),
        ),
      );
      final got = await readBack(quinlan, id);
      expect(got.linkPreview?.imagePath, linkImagePath(club, id));
      expect(_ok(await quinlan.linkImageBytes(linkImagePath(club, id))), _jpeg);
    },
  );

  test(
    'TARGET M1: a picture another member planted at the path is not '
    'taken as the sender\'s (409 counts only when the sender owns it)',
    () async {
      final id = randomMessageId();
      final url = page('planted');
      final planted = img.encodeJpg(img.Image(width: 2, height: 2));
      await quinlanClient.storage
          .from('link-previews')
          .uploadBinary(
            linkImagePath(club, id),
            planted,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          );
      final sent = await priya.send(
        id: id,
        conversationId: club,
        body: url,
        preview: draft(url, id, image: _jpeg),
      );
      if (sent is Ok<Message>) {
        final got = await readBack(quinlan, id);
        expect(
          got.linkPreview?.imagePath,
          isNull,
          reason: 'quinlan\'s planted picture must not show as priya\'s card',
        );
      }
    },
  );

  test('a non-member cannot read the picture', () async {
    final id = randomMessageId();
    final url = page('secret');
    _ok(
      await priya.send(
        id: id,
        conversationId: club,
        body: url,
        preview: draft(url, id, image: _jpeg),
      ),
    );
    final r = await remy.linkImageBytes(linkImagePath(club, id));
    expect(r, isA<Err<Uint8List>>());
    expect(r, isNot(isA<Ok<Uint8List>>()));
  });

  test(
    'deleting for everyone removes the card from what readers get',
    () async {
      final id = randomMessageId();
      final url = page('gone');
      final sent = _ok(
        await priya.send(
          id: id,
          conversationId: club,
          body: url,
          preview: draft(url, id, image: _jpeg),
        ),
      );
      _ok(await priya.deleteForEveryone(sent));
      final all = _ok(await quinlan.messages(club));
      for (final m in all.where((m) => m.id == id)) {
        expect(m.linkPreview, isNull);
      }
    },
  );

  test(
    'TARGET H1: after delete for everyone the picture is unreadable',
    () async {
      final id = randomMessageId();
      final url = page('gone2');
      final sent = _ok(
        await priya.send(
          id: id,
          conversationId: club,
          body: url,
          preview: draft(url, id, image: _jpeg),
        ),
      );
      _ok(await priya.deleteForEveryone(sent));
      expect(
        await quinlan.linkImageBytes(linkImagePath(club, id)),
        isA<Err<Uint8List>>(),
      );
    },
  );
}
