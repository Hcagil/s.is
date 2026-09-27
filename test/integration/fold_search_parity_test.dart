@Tags(['integration'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// In-chat search matches on the phone first (v0.18), with [foldSearch], and
/// on the server with public.fold_search. A message the phone matches and
/// the server does not (or the other way round) makes the counter lie, so
/// the two folds must agree for every input -- checked here against the
/// real database's own lower(), not against a copy of the rule.
///
/// Every code point in Unicode is folded on both sides (newline-separated,
/// in chunks), then strings whose fold depends on context or on more than
/// one code point: Turkish i forms, combining marks, emoji sequences, ß,
/// Greek final sigma.
///
/// Known, accepted differences are pinned below (v0.18 decision): Dart's
/// toLowerCase predates the capitals Unicode added for rarer scripts, and
/// does not apply Greek final sigma; the database's ICU lower() does both.
/// Anything outside the pinned set fails (new drift), and so does a pinned
/// entry that has started to agree (the list is then out of date: shrink it).
///
/// Requires a running local Supabase. Account vedat is the search suites'
/// own (supabase/seed.sql).
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);

String _hex(String s) =>
    s.runes.map((r) => 'U+${r.toRadixString(16).toUpperCase()}').join(' ');

/// Code points (inclusive ranges) the phone leaves as they are and the
/// database lowercases: Greek yot, Cyrillic/Latin/Coptic/Glagolitic
/// capitals added after Unicode 6, Georgian Mtavruli, Cherokee, Osage,
/// Vithkuqi, Old Hungarian, Warang Citi, Medefaidrin, Adlam.
const _knownCodePoints = [
  (0x037F, 0x037F),
  (0x0524, 0x0524),
  (0x0526, 0x0526),
  (0x0528, 0x0528),
  (0x052A, 0x052A),
  (0x052C, 0x052C),
  (0x052E, 0x052E),
  (0x10C7, 0x10C7),
  (0x10CD, 0x10CD),
  (0x13A0, 0x13F5),
  (0x1C90, 0x1CBA),
  (0x1CBD, 0x1CBF),
  (0x2C2F, 0x2C2F),
  (0x2C70, 0x2C70),
  (0x2C7E, 0x2C7F),
  (0x2CEB, 0x2CEB),
  (0x2CED, 0x2CED),
  (0x2CF2, 0x2CF2),
  (0xA660, 0xA660),
  (0xA698, 0xA698),
  (0xA69A, 0xA69A),
  (0xA78D, 0xA78D),
  (0xA790, 0xA790),
  (0xA792, 0xA792),
  (0xA796, 0xA796),
  (0xA798, 0xA798),
  (0xA79A, 0xA79A),
  (0xA79C, 0xA79C),
  (0xA79E, 0xA79E),
  (0xA7A0, 0xA7A0),
  (0xA7A2, 0xA7A2),
  (0xA7A4, 0xA7A4),
  (0xA7A6, 0xA7A6),
  (0xA7A8, 0xA7A8),
  (0xA7AA, 0xA7AE),
  (0xA7B0, 0xA7B4),
  (0xA7B6, 0xA7B6),
  (0xA7B8, 0xA7B8),
  (0xA7BA, 0xA7BA),
  (0xA7BC, 0xA7BC),
  (0xA7BE, 0xA7BE),
  (0xA7C0, 0xA7C0),
  (0xA7C2, 0xA7C2),
  (0xA7C4, 0xA7C7),
  (0xA7C9, 0xA7C9),
  (0xA7D0, 0xA7D0),
  (0xA7D6, 0xA7D6),
  (0xA7D8, 0xA7D8),
  (0xA7F5, 0xA7F5),
  (0x104B0, 0x104D3),
  (0x10570, 0x1057A),
  (0x1057C, 0x1058A),
  (0x1058C, 0x10592),
  (0x10594, 0x10595),
  (0x10C80, 0x10CB2),
  (0x118A0, 0x118BF),
  (0x16E40, 0x16E5F),
  (0x1E900, 0x1E921),
];

/// Context strings that fold differently: Greek final sigma (the database
/// writes ς at a word's end, the phone σ), and capitals from the ranges
/// above.
const _knownStrings = {
  'ΣΑΣ',
  'ΟΔΟΣ',
  'ΟΔΟΣ.',
  'ΣΟΣ ΣΟΣ',
  'ΌΣΟΣ',
  'ἈΣ',
  'ΑΣ́',
  'ᲐᲑᲒ',
  'ᎠᎡᎢ',
  'Ꭰa',
};

void main() {
  late SupabaseClient client;

  setUpAll(() async {
    client = SupabaseClient(
      _url,
      _key,
      authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit),
    );
    const email = 'vedat@integration.test', password = 'integration-password';
    try {
      await client.auth.signInWithPassword(email: email, password: password);
    } on AuthException {
      await client.auth.signUp(email: email, password: password);
    }
    expect(client.auth.currentUser, isNotNull, reason: 'sign-in failed');
  });

  tearDownAll(() => client.dispose());

  Future<String> server(String input) async =>
      await client.rpc('fold_search', params: {'input': input}) as String;

  test('the rpc answers: fixture sanity', () async {
    expect(await server('İSTANBUL'), 'istanbul');
  });

  test('every code point folds the same on the phone and on the server, '
      'but for the pinned ones', () async {
    final known = {
      for (final (a, b) in _knownCodePoints)
        for (var cp = a; cp <= b; cp++) cp,
    };
    expect(known, hasLength(410), reason: 'the pinned list as decided');
    // Not U+0000 (text cannot hold it), not surrogates (not characters).
    final all = [
      for (var cp = 1; cp <= 0x10FFFF; cp++)
        if (cp < 0xD800 || cp > 0xDFFF)
          if (cp != 0x0A) cp,
    ];
    const chunk = 32768;
    final differ = <int, String>{};
    for (var i = 0; i < all.length; i += chunk) {
      final part = all.sublist(i, (i + chunk).clamp(0, all.length));
      final input = part.map(String.fromCharCode).join('\n');
      final phone = foldSearch(input);
      final db = await server(input);
      if (phone == db) continue;
      final p = phone.split('\n'), d = db.split('\n');
      expect(p, hasLength(part.length));
      expect(d, hasLength(part.length));
      for (var k = 0; k < part.length; k++) {
        if (p[k] != d[k]) {
          differ[part[k]] = 'phone ${_hex(p[k])}, server ${_hex(d[k])}';
        }
      }
    }
    final drift = {
      for (final e in differ.entries)
        if (!known.contains(e.key))
          '${_hex(String.fromCharCode(e.key))}: ${e.value}',
    };
    final agreeNow = [
      for (final cp in known)
        if (!differ.containsKey(cp)) _hex(String.fromCharCode(cp)),
    ];
    expect(
      drift,
      isEmpty,
      reason:
          '${drift.length} code points fold differently, not pinned:\n'
          '${drift.join('\n')}',
    );
    expect(
      agreeNow,
      isEmpty,
      reason:
          '${agreeNow.length} pinned code points now fold the same: remove '
          'them from _knownCodePoints:\n${agreeNow.join('\n')}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('strings whose fold depends on context or sequences fold the same, '
      'but for the pinned ones', () async {
    const inputs = [
      // Turkish, and every dotted/dotless i sequence.
      'İstanbul ISTANBUL ıstanbul Istanbul istanbul',
      'İIıi', 'IĞDIR ığdır', 'ŞÇĞÜÖ şçğüö', 'KİLİT', 'DİYARBAKIR',
      'İ', 'i̇', 'İ̇', 'ı̇', 'Ï', 'İ́',
      'Į̇', 'J̇', // Lithuanian-style sequences
      // Combining marks, precomposed and not; compatibility letters.
      'é É é É', 'Å Å Å', 'Ω K',
      'Ǆ ǅ ǆ', 'ﬀ ﬁ ŉ',
      // German sharp s.
      'ß', 'ẞ', 'STRASSE straße STRAẞE',
      // Greek, incl. final sigma in every position.
      'Σ', 'ΣΑΣ', 'ΟΔΟΣ', 'ΟΔΟΣ.', 'ΣΟΣ ΣΟΣ', 'ΌΣΟΣ', 'ἈΣ', 'ΑΣ́',
      'ΐ ΰ Ϊ́', 'ς σ Σ',
      // Other scripts with case.
      'ԵՒ և', 'ᲐᲑᲒ', 'ᎠᎡᎢ', '𐐀𐐁 𐐨', 'ⰀⰁ',
      'ǅungla', 'Ꭰa',
      // Emoji: skin tones, ZWJ families, flags, keycaps, tags.
      '😂😂😂', '👍🏽', '👨‍👩‍👧', '🇹🇷', '1️⃣', '🏴󠁧󠁢󠁳󠁣󠁴󠁿',
      // Whitespace and punctuation are left alone.
      '  A\tB C  ', '', '%_\\',
    ];
    expect(inputs.toSet().containsAll(_knownStrings), isTrue);
    final differ = <String, String>{};
    for (final s in inputs) {
      final phone = foldSearch(s), db = await server(s);
      if (phone != db) {
        differ[s] = 'phone ${_hex(phone)}, server ${_hex(db)}';
      }
    }
    final drift = [
      for (final e in differ.entries)
        if (!_knownStrings.contains(e.key))
          '"${e.key}" (${_hex(e.key)}): ${e.value}',
    ];
    final agreeNow = [
      for (final s in _knownStrings)
        if (!differ.containsKey(s)) '"$s" (${_hex(s)})',
    ];
    expect(
      drift,
      isEmpty,
      reason:
          '${drift.length} strings fold differently, not pinned:\n'
          '${drift.join('\n')}',
    );
    expect(
      agreeNow,
      isEmpty,
      reason:
          '${agreeNow.length} pinned strings now fold the same: remove them '
          'from _knownStrings:\n${agreeNow.join('\n')}',
    );
  });
}
