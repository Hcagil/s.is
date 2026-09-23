// Link detection, written from the contract: what counts as a link, where it
// ends, and that splitting never loses or alters a character of the message.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/links.dart';

/// Segments as (text, link) pairs, so a whole split reads as one expectation.
List<(String, String?)> split(String text) => [
  for (final s in linkSegments(text)) (s.text, s.link?.toString()),
];

/// The links in [text] as the text they cover.
List<String> linkTexts(String text) => [
  for (final s in linkSegments(text))
    if (s.link != null) s.text,
];

/// Everything the contract says about ANY split, whatever the input.
void expectLawful(String input) {
  final segments = linkSegments(input);
  expect(
    segments.map((s) => s.text).join(),
    input,
    reason: 'splitting lost or altered text: ${_show(input)}',
  );
  for (final s in segments) {
    final link = s.link;
    if (link == null) continue;
    expect(
      link.scheme,
      anyOf('http', 'https'),
      reason: 'a non-web scheme became a link in ${_show(input)}',
    );
    expect(
      link.host,
      isNotEmpty,
      reason: 'a link with no host in ${_show(input)}',
    );
    expect(
      s.text,
      isNot(matches(RegExp(r'''[\s<>"']'''))),
      reason: 'a link ran past a terminator in ${_show(input)}',
    );
    expect(
      s.text,
      isNot(matches(RegExp(r'[.,;:!?]$'))),
      reason: 'trailing punctuation kept in ${_show(input)}',
    );
    final lower = s.text.toLowerCase();
    expect(
      link,
      lower.startsWith('http://') || lower.startsWith('https://')
          ? Uri.parse(s.text)
          : Uri.parse('https://${s.text}'),
      reason: 'the Uri does not match the text it covers in ${_show(input)}',
    );
  }
  expect(extractLinks(input), [
    for (final s in segments)
      if (s.link != null) s.link,
  ], reason: 'extractLinks disagrees with linkSegments for ${_show(input)}');
}

String _show(String s) => '"${s.replaceAll('\n', r'\n')}"';

void main() {
  group('plain text', () {
    test('text with no link is one plain run', () {
      expect(split('merhaba dünya'), [('merhaba dünya', null)]);
      expect(extractLinks('merhaba dünya'), isEmpty);
    });

    test('empty text has no links and loses nothing', () {
      expect(linkSegments('').map((s) => s.text).join(), '');
      expect(linkSegments('').where((s) => s.link != null), isEmpty);
      expect(extractLinks(''), isEmpty);
    });

    test('words that merely look webby are not links', () {
      for (final text in [
        'http',
        'https:',
        'www',
        'example.com',
        'dot.com bubble',
        'e-posta: ali@example.com',
        'saat 10:30, tamam mı?',
      ]) {
        expect(extractLinks(text), isEmpty, reason: _show(text));
        expectLawful(text);
      }
    });
  });

  group('recognised links', () {
    test('an https link inside a sentence', () {
      expect(split('see https://example.com now'), [
        ('see ', null),
        ('https://example.com', 'https://example.com'),
        (' now', null),
      ]);
    });

    test('an http link, path, query and fragment kept whole', () {
      const url = 'http://example.com/a/b.html?q=1,2&x=y.z#top';
      expect(split('go $url'), [('go ', null), (url, url)]);
    });

    test('a link that is the whole message', () {
      expect(split('https://sis.app'), [
        ('https://sis.app', 'https://sis.app'),
      ]);
    });

    test('schemes in any case', () {
      for (final url in [
        'HTTPS://EXAMPLE.COM',
        'Https://Example.com/Path',
        'hTtP://example.com',
        'HTTP://x.org/A?B=C',
      ]) {
        final segments = linkSegments('bak $url');
        expect(segments, hasLength(2), reason: url);
        expect(segments.last.text, url, reason: 'the text must be untouched');
        expect(segments.last.link, Uri.parse(url));
        expect(segments.last.link!.scheme, anyOf('http', 'https'));
      }
    });

    test('a www. address becomes https', () {
      expect(split('try www.example.com/page today'), [
        ('try ', null),
        ('www.example.com/page', 'https://www.example.com/page'),
        (' today', null),
      ]);
      expect(extractLinks('www.sis.app'), [Uri.parse('https://www.sis.app')]);
    });

    test('an https link to a www host is not prefixed twice', () {
      expect(extractLinks('https://www.example.com'), [
        Uri.parse('https://www.example.com'),
      ]);
      expect(extractLinks('http://www.example.com'), [
        Uri.parse('http://www.example.com'),
      ]);
    });

    test('several links, in order', () {
      const text =
          'a https://one.com b www.two.org c http://three.net/x d '
          'HTTPS://FOUR.IO';
      expect(linkTexts(text), [
        'https://one.com',
        'www.two.org',
        'http://three.net/x',
        'HTTPS://FOUR.IO',
      ]);
      expect(extractLinks(text), [
        Uri.parse('https://one.com'),
        Uri.parse('https://www.two.org'),
        Uri.parse('http://three.net/x'),
        Uri.parse('HTTPS://FOUR.IO'),
      ]);
      expectLawful(text);
    });

    test('links separated only by whitespace stay separate', () {
      expect(
        linkTexts('https://a.com https://b.com\nwww.c.com\thttp://d.com'),
        ['https://a.com', 'https://b.com', 'www.c.com', 'http://d.com'],
      );
    });

    test('the same link twice is reported twice', () {
      expect(extractLinks('https://a.com and https://a.com'), [
        Uri.parse('https://a.com'),
        Uri.parse('https://a.com'),
      ]);
    });
  });

  group('where a link ends', () {
    test('at whitespace of any kind', () {
      for (final ws in [' ', '\n', '\t', '\r\n']) {
        expect(linkTexts('https://x.com/a${ws}b'), [
          'https://x.com/a',
        ], reason: 'terminator ${_show(ws)}');
      }
    });

    for (final t in ['<', '>', '"', "'"]) {
      test('at a $t straight after the link', () {
        expect(split('https://x.com/a${t}b'), [
          ('https://x.com/a', 'https://x.com/a'),
          ('${t}b', null),
        ]);
        expect(linkTexts('www.x.com$t'), ['www.x.com']);
      });
    }

    test('at < > " and \' around it', () {
      expect(linkTexts('<https://x.com/a>'), ['https://x.com/a']);
      expect(split('<https://x.com/a>'), [
        ('<', null),
        ('https://x.com/a', 'https://x.com/a'),
        ('>', null),
      ]);
      expect(linkTexts('"https://x.com/a"'), ['https://x.com/a']);
      expect(linkTexts("'https://x.com/a'"), ['https://x.com/a']);
      expect(linkTexts('https://x.com/a"b'), ['https://x.com/a']);
      expect(linkTexts('<a href="https://x.com">'), ['https://x.com']);
      expect(linkTexts("href='www.x.com'"), ['www.x.com']);
    });

    for (final p in ['.', ',', ';', ':', '!', '?']) {
      test('a trailing "$p" is not part of the link', () {
        final text = 'look https://example.com/page$p next';
        expect(split(text), [
          ('look ', null),
          ('https://example.com/page', 'https://example.com/page'),
          ('$p next', null),
        ]);
        expect(linkTexts('www.example.com$p'), ['www.example.com']);
      });
    }

    test('a run of trailing punctuation is all dropped', () {
      expect(linkTexts('wow https://x.com!!!'), ['https://x.com']);
      expect(linkTexts('really https://x.com/a?!'), ['https://x.com/a']);
      expect(linkTexts('https://x.com/...'), ['https://x.com/']);
    });

    test('punctuation inside a link is kept', () {
      for (final url in [
        'https://x.com/a.b/c,d;e:f!g?h=i',
        'https://x.com:8080/path',
        'https://x.com/?q=a.b',
      ]) {
        expect(linkTexts('$url end'), [url]);
      }
    });

    test('a balanced ) belongs to the link', () {
      const url = 'https://en.wikipedia.org/wiki/Foo_(bar)';
      expect(split('read $url'), [('read ', null), (url, url)]);
      expect(linkTexts('$url.'), [url]);
    });

    test('an unbalanced trailing ) closes the sentence, not the link', () {
      expect(split('(see https://x.com)'), [
        ('(see ', null),
        ('https://x.com', 'https://x.com'),
        (')', null),
      ]);
      expect(linkTexts('(www.x.com)'), ['www.x.com']);
    });

    test('a wrapped wikipedia link keeps its own ) only', () {
      const url = 'https://en.wikipedia.org/wiki/Foo_(bar)';
      expect(split('($url)'), [('(', null), (url, url), (')', null)]);
    });

    test('punctuation after a closing ) goes with the sentence', () {
      expect(linkTexts('(see https://x.com).'), ['https://x.com']);
      expect(linkTexts('(see https://x.com.)'), ['https://x.com']);
    });
  });

  group('never links', () {
    test('a match with no host stays plain text', () {
      for (final text in [
        'https://',
        'http://',
        'https:// x',
        'https:///path',
        'https://?q=1',
        'https://#frag',
        'HTTPS://.',
      ]) {
        expect(extractLinks(text), isEmpty, reason: _show(text));
        expectLawful(text);
      }
    });

    test('dangerous and non-web schemes are never links', () {
      for (final text in [
        'javascript:alert(1)',
        'JavaScript:alert(document.cookie)',
        'javascript://example.com/%0Aalert(1)',
        'mailto:ali@example.com',
        'MAILTO:ali@example.com?subject=hi',
        'intent://scan/#Intent;scheme=zxing;package=com.x;end',
        'ftp://files.example.com/a.zip',
        'file:///etc/passwd',
        'file://localhost/etc/hosts',
        'data:text/html,<script>alert(1)</script>',
        'tel:+905551112233',
        'sms:+905551112233',
        'market://details?id=com.esd.sis',
        'content://com.android.contacts/contacts',
        'vbscript:msgbox(1)',
      ]) {
        expect(split('bak $text'), [('bak $text', null)], reason: text);
        expect(extractLinks(text), isEmpty, reason: text);
      }
    });

    test('a web link hidden inside another scheme is still only http(s)', () {
      for (final text in [
        'javascript:fetch("https://evil.com")',
        'intent://www.evil.com#Intent;end',
        'mailto:x@www.example.com',
      ]) {
        expectLawful(text);
      }
    });
  });

  group('text around links survives', () {
    test('Turkish text', () {
      const text =
          'Şu linke bak: https://örnek.com.tr/çay?şeker=1 güzel mi? '
          'İyi akşamlar, ığdır ÇÖĞÜŞ www.ılık.com.';
      final links = linkSegments(text).where((s) => s.link != null).toList();
      expect(links.map((s) => s.text), [
        'https://örnek.com.tr/çay?şeker=1',
        'www.ılık.com',
      ]);
      for (final s in links) {
        expect(s.link!.host, isNotEmpty);
      }
      expectLawful(text);
    });

    test('emoji before, between and after links', () {
      const text = '🎉 https://x.com 🎉\n👩‍👩‍👧 www.y.org 🇹🇷!';
      expect(linkTexts(text), ['https://x.com', 'www.y.org']);
      expectLawful(text);
      expect(linkTexts('👍https://x.com'), ['https://x.com']);
      expectLawful('👍https://x.com');
    });

    test('a long message with many links round-trips', () {
      final text = List.generate(
        40,
        (i) => 'satır $i: https://site$i.com/p?i=$i, www.w$i.net. ',
      ).join('\n');
      expect(extractLinks(text), hasLength(80));
      expectLawful(text);
    });
  });

  group('every split is lawful', () {
    test('a corpus of awkward inputs', () {
      for (final text in [
        'https://x.com',
        'https://x.com.',
        '(https://x.com)',
        '((https://x.com/a_(b)))',
        'https://x.com/a)b',
        'https://x.com/(a',
        '....https://x.com....',
        '"https://x.com"\'',
        'www.x.com<www.y.com>www.z.com',
        'https://https://x.com',
        'http://http://',
        'hTTps://x.com?,.;:!',
        'a https://x.com b',
        'https://x.com​b',
        '\u{1F600}' * 5,
        'ğüşiöç ĞÜŞİÖÇ ıI',
        '   ',
        '\n\n',
      ]) {
        expectLawful(text);
      }
    });

    test('2000 random mixes of links, punctuation, emoji and Turkish', () {
      const pieces = [
        'https://',
        'http://',
        'HTTPS://',
        'www.',
        'javascript:',
        'mailto:',
        'ftp://',
        'file://',
        'intent://',
        'example',
        '.com',
        '.tr',
        '/',
        '?',
        '=',
        '&',
        '#',
        '.',
        ',',
        ';',
        ':',
        '!',
        '(',
        ')',
        '<',
        '>',
        '"',
        "'",
        ' ',
        ' ',
        '\n',
        '\t',
        'ş',
        'ğ',
        'İ',
        'ı',
        'çay',
        '🎉',
        '👩‍👩‍👧',
        '🇹🇷',
        'a',
        'Z',
        '9',
        '-',
        '_',
        '%20',
      ];
      final random = Random(20260923);
      for (var i = 0; i < 2000; i++) {
        final text = List.generate(
          random.nextInt(24),
          (_) => pieces[random.nextInt(pieces.length)],
        ).join();
        expectLawful(text);
      }
    });
  });

  test('TextSegment carries its text and optional link', () {
    const plain = TextSegment('hi');
    expect(plain.text, 'hi');
    expect(plain.link, isNull);
    final link = TextSegment('www.x.com', Uri.parse('https://www.x.com'));
    expect(link.link, Uri.parse('https://www.x.com'));
  });
}
