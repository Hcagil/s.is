import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/link_preview.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';

void main() {
  group('encodeEnvelope', () {
    const id = 'm1';
    const text = 'Hello world';

    test('no card -> lp null', () {
      final json = encodeEnvelope(id: id, text: text, card: null);
      final map = jsonDecode(json) as Map<String, dynamic>;
      expect(map.containsKey('lp'), isTrue);
      expect(map['lp'], isNull);
    });

    test('card with all fields', () {
      final card = LinkPreview(
        url: Uri.parse('https://example.com'),
        title: 'Title',
        description: 'Desc',
        site: 'Site',
        imagePath: 'path',
        video: true,
      );
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final lp = map['lp'] as Map<String, dynamic>;
      expect(lp['url'], equals(card.url.toString()));
      expect(lp['title'], equals(card.title));
      expect(lp['description'], equals(card.description));
      expect(lp['site'], equals(card.site));
      expect(lp['video'], isTrue);
      expect(lp.keys.toSet(), {'url', 'title', 'description', 'site', 'video'});
    });

    test('card omits optional fields', () {
      final card = LinkPreview(
        url: Uri.parse('https://example.com'),
        title: 'Title',
      );
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final lp = map['lp'] as Map<String, dynamic>;
      expect(lp.containsKey('description'), isFalse);
      expect(lp.containsKey('site'), isFalse);
      expect(lp.containsKey('video'), isFalse);
      expect(lp.keys.toSet(), {'url', 'title'});
    });

    test(
      'a card with an imagePath and video false: no image key, no video key',
      () {
        final card = LinkPreview(
          url: Uri.parse('https://example.com'),
          title: 'Title',
          imagePath: '/data/pic.jpg',
        );
        final map = jsonDecode(
          encodeEnvelope(id: id, text: text, card: card),
        ) as Map<String, dynamic>;
        expect((map['lp'] as Map).keys.toSet(), {'url', 'title'});
        expect(map.keys.toSet(), {'v', 'i', 't', 'lp'});
      },
    );

    test('values at the caps are kept whole', () {
      final card = LinkPreview(
        url: Uri.parse('https://example.com'),
        title: 'a' * 200,
        description: 'b' * 400,
        site: 'c' * 100,
      );
      final lp =
          (jsonDecode(encodeEnvelope(id: id, text: text, card: card))
                  as Map)['lp']
              as Map;
      expect(lp['title'], 'a' * 200);
      expect(lp['description'], 'b' * 400);
      expect(lp['site'], 'c' * 100);
    });

    test('title capped to 200', () {
      final longTitle = 'a' * 201;
      final card = LinkPreview(
        url: Uri.parse('https://example.com'),
        title: longTitle,
      );
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final lp = map['lp'] as Map<String, dynamic>;
      expect(lp['title'].length, equals(200));
      expect(lp['title'], equals('a' * 200));
    });

    test('description capped to 400', () {
      final longDesc = 'b' * 401;
      final card = LinkPreview(
        url: Uri.parse('https://example.com'),
        title: 'Title',
        description: longDesc,
      );
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final lp = map['lp'] as Map<String, dynamic>;
      expect(lp['description'].length, equals(400));
      expect(lp['description'], equals('b' * 400));
    });

    test('site capped to 100', () {
      final longSite = 'c' * 101;
      final card = LinkPreview(
        url: Uri.parse('https://example.com'),
        title: 'Title',
        site: longSite,
      );
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final lp = map['lp'] as Map<String, dynamic>;
      expect(lp['site'].length, equals(100));
      expect(lp['site'], equals('c' * 100));
    });

    test('surrogate pair not split in title', () {
      final title = 'a' * 199 + '😀' + 'b';
      final card = LinkPreview(
        url: Uri.parse('https://example.com'),
        title: title,
      );
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final lp = map['lp'] as Map<String, dynamic>;
      expect(lp['title'].length, equals(199));
      expect(lp['title'], equals('a' * 199));
    });

    test('surrogate pair fits fully in title', () {
      final title = 'a' * 198 + '😀' + 'tail';
      final card = LinkPreview(
        url: Uri.parse('https://example.com'),
        title: title,
      );
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final lp = map['lp'] as Map<String, dynamic>;
      expect(lp['title'].length, equals(200));
      expect(lp['title'], equals('a' * 198 + '😀'));
    });

    test('surrogate pair not split in description', () {
      final desc = 'b' * 399 + '😀' + 'c';
      final card = LinkPreview(
        url: Uri.parse('https://example.com'),
        title: 'Title',
        description: desc,
      );
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final lp = map['lp'] as Map<String, dynamic>;
      expect(lp['description'].length, equals(399));
      expect(lp['description'], equals('b' * 399));
    });

    test('surrogate pair fits fully in description', () {
      final desc = 'b' * 398 + '😀' + 'tail';
      final card = LinkPreview(
        url: Uri.parse('https://example.com'),
        title: 'Title',
        description: desc,
      );
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final lp = map['lp'] as Map<String, dynamic>;
      expect(lp['description'].length, equals(400));
      expect(lp['description'], equals('b' * 398 + '😀'));
    });

    test('surrogate pair not split in site', () {
      final site = 'c' * 99 + '😀' + 'd';
      final card = LinkPreview(
        url: Uri.parse('https://example.com'),
        title: 'Title',
        site: site,
      );
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final lp = map['lp'] as Map<String, dynamic>;
      expect(lp['site'].length, equals(99));
      expect(lp['site'], equals('c' * 99));
    });

    test('surrogate pair fits fully in site', () {
      final site = 'c' * 98 + '😀' + 'tail';
      final card = LinkPreview(
        url: Uri.parse('https://example.com'),
        title: 'Title',
        site: site,
      );
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final lp = map['lp'] as Map<String, dynamic>;
      expect(lp['site'].length, equals(100));
      expect(lp['site'], equals('c' * 98 + '😀'));
    });

    test('url length >2000 -> lp null', () {
      final longUrl = Uri.parse('https://e.test/${'a' * 1986}');
      final card = LinkPreview(url: longUrl, title: 'Title');
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      expect(map['lp'], isNull);
    });

    test('url length exactly 2000 -> lp kept', () {
      final exactUrl = Uri.parse('https://e.test/${'a' * 1985}');
      final card = LinkPreview(url: exactUrl, title: 'Title');
      final json = encodeEnvelope(id: id, text: text, card: card);
      final map = jsonDecode(json) as Map<String, dynamic>;
      final lp = map['lp'] as Map<String, dynamic>;
      expect(lp['url'].length, equals(2000));
      expect(lp['url'], equals(exactUrl.toString()));
    });

    test('text roundtrip with emoji and newlines', () {
      final txt = 'Hello\nWorld 😀';
      final json = encodeEnvelope(id: id, text: txt, card: null);
      final map = jsonDecode(json) as Map<String, dynamic>;
      expect(map['t'], equals(txt));
      expect(map['i'], equals(id));
      expect(map['v'], equals(1));
    });
  });

  group('withPlain', () {
    final now = DateTime.now();
    final original = Message(
      id: 'm1',
      conversationId: 'c1',
      senderId: 'u1',
      body: 'original',
      createdAt: now,
      replyTo: 'r1',
      editedAt: now,
      forwarded: true,
      linkPreview: LinkPreview(
        url: Uri.parse('https://example.com'),
        title: 'Title',
      ),
    );

    test('fields copied and body/linkPreview replaced', () {
      final newCard = LinkPreview(
        url: Uri.parse('https://new.com'),
        title: 'New',
      );
      final updated = original.withPlain('new text', newCard);
      expect(updated.body, equals('new text'));
      expect(updated.linkPreview, equals(newCard));
      expect(updated.id, equals(original.id));
      expect(updated.conversationId, equals(original.conversationId));
      expect(updated.senderId, equals(original.senderId));
      expect(updated.createdAt, equals(original.createdAt));
      expect(updated.replyTo, equals(original.replyTo));
      expect(updated.editedAt, equals(original.editedAt));
      expect(updated.forwarded, equals(original.forwarded));
    });

    test('withPlain(text, null) clears linkPreview', () {
      final updated = original.withPlain('new text', null);
      expect(updated.linkPreview, isNull);
      expect(updated.body, equals('new text'));
    });
  });
}
