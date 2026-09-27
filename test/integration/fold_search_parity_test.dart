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

  test(
    'every code point folds the same on the phone and on the server',
    () async {
      // Not U+0000 (text cannot hold it), not surrogates (not characters).
      final all = [
        for (var cp = 1; cp <= 0x10FFFF; cp++)
          if (cp < 0xD800 || cp > 0xDFFF)
            if (cp != 0x0A) cp,
      ];
      const chunk = 32768;
      final mismatches = <String>[];
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
            mismatches.add(
              '${_hex(String.fromCharCode(part[k]))}: phone ${_hex(p[k])}, '
              'server ${_hex(d[k])}',
            );
          }
        }
      }
      expect(
        mismatches,
        isEmpty,
        reason:
            '${mismatches.length} code points fold differently:\n'
            '${mismatches.join('\n')}',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'strings whose fold depends on context or sequences fold the same',
    () async {
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
        'ԵՒ և', 'ᲐᲑᲒ', 'ᎠᎡᎢ', '𐐀𐐁 𐐨', 'ⰀⰁ', 'ǅungla', 'Ꭰa',
        // Emoji: skin tones, ZWJ families, flags, keycaps, tags.
        '😂😂😂', '👍🏽', '👨‍👩‍👧', '🇹🇷', '1️⃣', '🏴󠁧󠁢󠁳󠁣󠁴󠁿',
        // Whitespace and punctuation are left alone.
        '  A\tB C  ', '', '%_\\',
      ];
      final mismatches = <String>[];
      for (final s in inputs) {
        final phone = foldSearch(s), db = await server(s);
        if (phone != db) {
          mismatches.add(
            '"$s" (${_hex(s)}): phone ${_hex(phone)}, server ${_hex(db)}',
          );
        }
      }
      expect(
        mismatches,
        isEmpty,
        reason:
            '${mismatches.length} strings fold differently:\n'
            '${mismatches.join('\n')}',
      );
    },
  );
}
