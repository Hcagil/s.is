// parseWhatsNewNote with the build suffix "(216)" on the version line,
// from its contract (fix/tester-findings).
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/update/domain/whats_new_note.dart';

void main() {
  test('parses version line with build and bullets', () {
    final body = 'Version 0.31.0 (216)\n- a\n- b';
    final note = parseWhatsNewNote(body);
    expect(note.version, equals('0.31.0'));
    expect(note.build, equals(216));
    expect(note.bullets, equals(['a', 'b']));
    expect(note.isStructured, isTrue);
  });

  test('parses v0.31 (5) format', () {
    final body = 'v0.31 (5)\n- a\n- b';
    final note = parseWhatsNewNote(body);
    expect(note.version, equals('0.31'));
    expect(note.build, equals(5));
    expect(note.bullets, equals(['a', 'b']));
    expect(note.isStructured, isTrue);
  });

  test('parses sürüm 0.31.0 (216) format', () {
    final body = 'sürüm 0.31.0 (216)\n- a\n- b';
    final note = parseWhatsNewNote(body);
    expect(note.version, equals('0.31.0'));
    expect(note.build, equals(216));
    expect(note.bullets, equals(['a', 'b']));
    expect(note.isStructured, isTrue);
  });

  test('parses 0.31.0(216) without space before parenthesis', () {
    final body = '0.31.0(216)\n- a\n- b';
    final note = parseWhatsNewNote(body);
    expect(note.version, equals('0.31.0'));
    expect(note.build, equals(216));
    expect(note.bullets, equals(['a', 'b']));
    expect(note.isStructured, isTrue);
  });

  test('parses version line without build', () {
    final body = 'Version 0.31.0\n- a\n- b';
    final note = parseWhatsNewNote(body);
    expect(note.version, equals('0.31.0'));
    expect(note.build, isNull);
    expect(note.bullets, equals(['a', 'b']));
    expect(note.isStructured, isTrue);
  });

  test('does not treat invalid build string as version line', () {
    final body = 'Version 0.31.0 (abc)\n- a\n- b';
    final note = parseWhatsNewNote(body);
    expect(note.version, isNull);
    expect(note.build, isNull);
    expect(note.bullets, isEmpty); // a plain note keeps no bullets
    expect(note.isStructured, isFalse);
  });

  test('handles body with no version line', () {
    final body = '- a\n- b';
    final note = parseWhatsNewNote(body);
    expect(note.version, isNull);
    expect(note.build, isNull);
    expect(note.bullets, isEmpty); // a plain note keeps no bullets
    expect(note.isStructured, isFalse);
  });

  test('bilingual note selects English side when lang is en', () {
    final body = '''
Version 0.31.0 (216)
- Chats load faster
---
Sürüm 0.31.0 (216)
- Sohbetler hızlı açılır
''';
    final note = parseWhatsNewNote(body, lang: 'en');
    expect(note.version, equals('0.31.0'));
    expect(note.build, equals(216));
    expect(note.bullets, equals(['Chats load faster']));
    expect(note.isStructured, isTrue);
  });

  test('bilingual note selects Turkish side when lang is tr', () {
    final body = '''
Version 0.31.0 (216)
- Chats load faster
---
Sürüm 0.31.0 (216)
- Sohbetler hızlı açılır
''';
    final note = parseWhatsNewNote(body, lang: 'tr');
    expect(note.version, equals('0.31.0'));
    expect(note.build, equals(216));
    expect(note.bullets, equals(['Sohbetler hızlı açılır']));
    expect(note.isStructured, isTrue);
  });

  test('each side keeps its own suffix (English side has build)', () {
    final body = '''
Version 0.31.0 (216)
- a
---
Sürüm 0.31.0
- b
''';
    final noteEn = parseWhatsNewNote(body, lang: 'en');
    final noteTr = parseWhatsNewNote(body, lang: 'tr');
    expect(noteEn.build, equals(216));
    expect(noteTr.build, isNull);
  });

  test('each side keeps its own suffix (Turkish side has build)', () {
    final body = '''
Version 0.31.0
- a
---
Sürüm 0.31.0 (7)
- b
''';
    final noteEn = parseWhatsNewNote(body, lang: 'en');
    final noteTr = parseWhatsNewNote(body, lang: 'tr');
    expect(noteEn.build, isNull);
    expect(noteTr.build, equals(7));
  });
}
