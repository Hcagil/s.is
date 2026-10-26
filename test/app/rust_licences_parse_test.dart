// parseRustLicences: one licence entry per @@@@ block, crate names without versions.
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/app/rust_licences.dart';

void main() {
  test('single block with one crate', () {
    final input = 'vodozemac 0.9.0\n\nApache License text';
    final entries = parseRustLicences(input).toList();

    expect(entries.length, 1);
    final e = entries[0];
    expect(e.packages.toList(), ['vodozemac']);

    final text = e.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('Apache License text'));
    // The crate header line is not part of the licence text.
    expect(text, isNot(contains('0.9.0')));
  });

  test('single block with two crates', () {
    final input = 'addr2line 0.21.0, matrix-pickle 0.2.1\n\nMIT text';
    final entries = parseRustLicences(input).toList();

    expect(entries.length, 1);
    final e = entries[0];
    expect(e.packages.toList(), ['addr2line', 'matrix-pickle']);

    final text = e.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('MIT text'));
  });

  test('two blocks separated by @@@@', () {
    final input = 'crate1 1.0.0\n\nText1\n@@@@\ncrate2 2.0.0\n\nText2';
    final entries = parseRustLicences(input).toList();

    expect(entries.length, 2);
    final e1 = entries[0];
    final e2 = entries[1];

    final text1 = e1.paragraphs.map((p) => p.text).join('\n');
    final text2 = e2.paragraphs.map((p) => p.text).join('\n');

    expect(text1, contains('Text1'));
    expect(text1, isNot(contains('Text2')));
    expect(text1, isNot(contains('@@@@')));

    expect(text2, contains('Text2'));
    expect(e1.packages.toList(), ['crate1']);
    expect(e2.packages.toList(), ['crate2']);
  });

  test('three blocks', () {
    final input =
        'crate1 1.0.0\n\nText1\n@@@@\ncrate2 2.0.0\n\nText2\n@@@@\ncrate3 3.0.0\n\nText3';
    final entries = parseRustLicences(input).toList();

    expect(entries.length, 3);
  });
}
