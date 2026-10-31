import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/reaction_envelope.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';

void main() {
  const messageIdA = '11111111-1111-4111-8111-111111111111';
  const messageIdB = '22222222-2222-4222-8222-222222222222';
  const userIdU = '33333333-3333-4333-8333-333333333333';
  const userIdW = '44444444-4444-4444-8444-444444444444';

  // Helper to assert length and padding
  void checkLengthAndPadding(String jsonStr) {
    final bytes = utf8.encode(jsonStr);
    expect(bytes.length, equals(192)); // F3
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    expect(map['p'], isA<String>());
    final padding = map['p'] as String;
    expect(padding.split('').every((c) => c == ' '), isTrue);
  }

  // Test emojis
  final emojis = <String>[
    '👍',
    '❤️',
    '👍🏽',
    '👨‍👩‍👧',
    'a',
    List.filled(16, '😀').join(''), // 64 UTF-8 bytes
  ];

  for (final emoji in emojis) {
    test('encodeReactionEnvelope length 192 (F3) for "$emoji"', () {
      final jsonStr = encodeReactionEnvelope(
        messageId: messageIdA,
        userId: userIdU,
        emoji: emoji,
      );
      checkLengthAndPadding(jsonStr);
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      expect(map['v'], equals(1));
      expect(map['k'], equals('r'));
      expect(map['i'], equals(messageIdA));
      expect(map['u'], equals(userIdU));
      expect(map['e'], equals(emoji));
    });

    test('round trip for "$emoji"', () {
      final jsonStr = encodeReactionEnvelope(
        messageId: messageIdA,
        userId: userIdU,
        emoji: emoji,
      );
      final decoded = decodeReactionEnvelope(
        jsonStr,
        messageId: messageIdA,
        userId: userIdU,
      );
      expect(decoded, equals(emoji));
    });
  }

  // Null cases
  final nullCases = <String, String>{
    // not valid JSON
    'not JSON': 'not json',
    // JSON not object
    'a JSON list': jsonEncode(['a', 'b']),
    'a JSON string': jsonEncode('string'),
    'a JSON number': jsonEncode(123),
    // v not 1
    'v 2': jsonEncode({
      'v': 2,
      'k': 'r',
      'i': messageIdA,
      'u': userIdU,
      'e': '👍',
      'p': ' ',
    }),
    'v "1"': jsonEncode({
      'v': '1',
      'k': 'r',
      'i': messageIdA,
      'u': userIdU,
      'e': '👍',
      'p': ' ',
    }),
    'v missing': jsonEncode({
      'k': 'r',
      'i': messageIdA,
      'u': userIdU,
      'e': '👍',
      'p': ' ',
    }),
    // k not "r"
    'k missing (a message envelope)': jsonEncode({
      'v': 1,
      'i': messageIdA,
      'u': userIdU,
      'e': '👍',
      'p': ' ',
    }),
    'k "m"': jsonEncode({
      'v': 1,
      'k': 'm',
      'i': messageIdA,
      'u': userIdU,
      'e': '👍',
      'p': ' ',
    }),
    // i different or missing
    'i of another message': jsonEncode({
      'v': 1,
      'k': 'r',
      'i': messageIdB,
      'u': userIdU,
      'e': '👍',
      'p': ' ',
    }),
    'i missing': jsonEncode({
      'v': 1,
      'k': 'r',
      'u': userIdU,
      'e': '👍',
      'p': ' ',
    }),
    // u different or missing
    'u of another user': jsonEncode({
      'v': 1,
      'k': 'r',
      'i': messageIdA,
      'u': userIdW,
      'e': '👍',
      'p': ' ',
    }),
    'u missing': jsonEncode({
      'v': 1,
      'k': 'r',
      'i': messageIdA,
      'e': '👍',
      'p': ' ',
    }),
    // e empty string
    'e empty': jsonEncode({
      'v': 1,
      'k': 'r',
      'i': messageIdA,
      'u': userIdU,
      'e': '',
      'p': ' ',
    }),
    // e not string
    'e a number': jsonEncode({
      'v': 1,
      'k': 'r',
      'i': messageIdA,
      'u': userIdU,
      'e': 123,
      'p': ' ',
    }),
    'e missing': jsonEncode({
      'v': 1,
      'k': 'r',
      'i': messageIdA,
      'u': userIdU,
      'p': ' ',
    }),
  };

  test(
    'control: a hand-made valid map opens (each null case changes one field)',
    () {
      final j = jsonEncode({
        'v': 1,
        'k': 'r',
        'i': messageIdA,
        'u': userIdU,
        'e': '👍',
        'p': ' ',
      });
      expect(
        decodeReactionEnvelope(j, messageId: messageIdA, userId: userIdU),
        '👍',
      );
    },
  );

  nullCases['e null'] = jsonEncode({
    'v': 1,
    'k': 'r',
    'i': messageIdA,
    'u': userIdU,
    'e': null,
    'p': ' ',
  });
  for (final MapEntry(key: name, value: jsonStr) in nullCases.entries) {
    test('decodeReactionEnvelope returns null for $name', () {
      final decoded = decodeReactionEnvelope(
        jsonStr,
        messageId: messageIdA,
        userId: userIdU,
      );
      expect(decoded, isNull);
    });
  }

  test('the length does not tell two emojis apart', () {
    String e(String emoji) => encodeReactionEnvelope(
      messageId: messageIdA,
      userId: userIdU,
      emoji: emoji,
    );
    expect(
      utf8.encode(e('a')).length,
      utf8.encode(e(List.filled(16, '😀').join())).length,
    );
  });

  test('an envelope for message A or user U never opens as B or W', () {
    final j = encodeReactionEnvelope(
      messageId: messageIdA,
      userId: userIdU,
      emoji: '👍',
    );
    expect(
      decodeReactionEnvelope(j, messageId: messageIdB, userId: userIdU),
      isNull,
    );
    expect(
      decodeReactionEnvelope(j, messageId: messageIdA, userId: userIdW),
      isNull,
    );
    expect(
      decodeReactionEnvelope(j, messageId: messageIdA, userId: userIdU),
      '👍',
    );
  });

  // Cross-kind cases
  test('reaction envelope does not decode as message', () {
    final reactionJson = encodeReactionEnvelope(
      messageId: messageIdA,
      userId: userIdU,
      emoji: '👍',
    );
    final decoded = decodeEnvelope(reactionJson, messageIdA);
    expect(decoded, isNull);
  });

  test('message envelope does not decode as reaction', () {
    final messageJson = encodeEnvelope(id: messageIdA, text: '👍');
    final decoded = decodeReactionEnvelope(
      messageJson,
      messageId: messageIdA,
      userId: userIdU,
    );
    expect(decoded, isNull);
  });

  // F2 (round 2): the emoji is at most maxReactionEmojiBytes (64) UTF-8 bytes;
  // a longer one is refused on decode. Multi-byte characters hit the limit.
  group('emoji size limit', () {
    final at64 = '😀' * 16; // 16 x 4 bytes
    final at65 = '${'😀' * 14}❤️€'; // 56 + 6 + 3 bytes
    test('fixtures are 64 and 65 UTF-8 bytes', () {
      expect(maxReactionEmojiBytes, 64);
      expect(utf8.encode(at64).length, 64);
      expect(utf8.encode(at65).length, 65);
    });
    test('an emoji of exactly 64 bytes decodes', () {
      final json = encodeReactionEnvelope(
        messageId: messageIdA,
        userId: userIdU,
        emoji: at64,
      );
      expect(
        decodeReactionEnvelope(json, messageId: messageIdA, userId: userIdU),
        at64,
      );
    });
    test('an emoji of 65 bytes is refused (null)', () {
      final json = jsonEncode({
        'v': 1,
        'k': 'r',
        'i': messageIdA,
        'u': userIdU,
        'e': at65,
        'p': ' ',
      });
      expect(
        decodeReactionEnvelope(json, messageId: messageIdA, userId: userIdU),
        isNull,
      );
      final encoded = encodeReactionEnvelope(
        messageId: messageIdA,
        userId: userIdU,
        emoji: at65,
      );
      expect(
        decodeReactionEnvelope(encoded, messageId: messageIdA, userId: userIdU),
        isNull,
      );
    });
  });
}
