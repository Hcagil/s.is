// parseReactionPush, written by QA from the contract: null unless every id is
// a lowercase UUID, optional fields kept only when non-empty, ct needs ot 0/1.

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/domain/reaction_push.dart';

const u = '11111111-1111-4111-8111-111111111111';
const c = '22222222-2222-4222-8222-222222222222';
const m = '33333333-3333-4333-8333-333333333333';
const r = '44444444-4444-4444-8444-444444444444';

Map<String, dynamic> base([Map<String, dynamic> extra = const {}]) => {
  'kind': 'reaction',
  'user_id': u,
  'conversation_id': c,
  'message_id': m,
  'reactor_id': r,
  ...extra,
};

void main() {
  test('ids and plain fields are kept', () {
    final p = parseReactionPush(base({'e': '👍', 'q': 'hi', 'qk': 'photo'}))!;
    expect(p.userId, u);
    expect(p.conversationId, c);
    expect(p.messageId, m);
    expect(p.reactorId, r);
    expect(p.emoji, '👍');
    expect(p.quote, 'hi');
    expect(p.quoteKind, 'photo');
    expect(p.ciphertext, isNull);
    expect(p.olmType, isNull);
  });

  test('other kind or no kind: null', () {
    expect(parseReactionPush(base({'kind': 'message'})), isNull);
    expect(parseReactionPush(base()..remove('kind')), isNull);
  });

  for (final key in [
    'user_id',
    'conversation_id',
    'message_id',
    'reactor_id',
  ]) {
    test('$key missing, bad shape, uppercase or empty: null', () {
      expect(parseReactionPush(base()..remove(key)), isNull);
      expect(parseReactionPush(base({key: 'nope'})), isNull);
      expect(
        parseReactionPush(
          base({key: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'.toUpperCase()}),
        ),
        isNull,
      );
      expect(parseReactionPush(base({key: ''})), isNull);
      expect(parseReactionPush(base({key: 5})), isNull);
    });
  }

  test('empty e, q, qk are dropped', () {
    final p = parseReactionPush(base({'e': '', 'q': '', 'qk': ''}))!;
    expect(p.emoji, isNull);
    expect(p.quote, isNull);
    expect(p.quoteKind, isNull);
  });

  test('ct with ot 0 or 1 is kept', () {
    expect(parseReactionPush(base({'ct': 'x', 'ot': '0'}))!.olmType, 0);
    final p = parseReactionPush(base({'ct': 'x', 'ot': '1'}))!;
    expect(p.olmType, 1);
    expect(p.ciphertext, 'x');
  });

  test('ct with missing, bad or out-of-range ot: null', () {
    expect(parseReactionPush(base({'ct': 'x'})), isNull);
    expect(parseReactionPush(base({'ct': 'x', 'ot': 'a'})), isNull);
    expect(parseReactionPush(base({'ct': 'x', 'ot': '2'})), isNull);
    expect(parseReactionPush(base({'ct': 'x', 'ot': ''})), isNull);
  });

  test('empty ct counts as absent', () {
    final p = parseReactionPush(base({'ct': '', 'e': 'x'}))!;
    expect(p.ciphertext, isNull);
  });
}
