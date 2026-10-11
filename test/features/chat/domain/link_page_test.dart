import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/domain/link_page.dart';

void main() {
  final base = Uri.parse('https://example.com/post/1');

  test('full OG page with relative image', () {
    final html = '''
      <html>
        <head>
          <meta property="og:title" content="OG Title">
          <meta property="og:description" content="OG Description">
          <meta property="og:site_name" content="OG Site">
          <meta property="og:image" content="/img/a.png">
        </head>
      </html>
    ''';
    final info = parseLinkPage(base, html);
    expect(info, isNotNull);
    expect(info!.title, 'OG Title');
    expect(info.description, 'OG Description');
    expect(info.site, 'OG Site');
    expect(info.image, Uri.parse('https://example.com/img/a.png'));
  });

  test('fallback to <title> when no og:title', () {
    final html = '<title>Page Title</title>';
    final info = parseLinkPage(base, html);
    expect(info, isNotNull);
    expect(info!.title, 'Page Title');
  });

  test('fallback to twitter:title when no og:title', () {
    final html = '<meta name="twitter:title" content="Twitter Title">';
    final info = parseLinkPage(base, html);
    expect(info, isNotNull);
    expect(info!.title, 'Twitter Title');
  });

  test('null when no title at all', () {
    final html = '<meta name="description" content="Desc">';
    final info = parseLinkPage(base, html);
    expect(info, isNull);
  });

  test('null when title is whitespace only', () {
    final html = '<title>   \n\t  </title>';
    final info = parseLinkPage(base, html);
    expect(info, isNull);
  });

  test('entities decoded in og:title', () {
    final html =
        '<meta property="og:title" content="Tom &amp; Jerry &#39;s &#x27;x&#x27;">';
    final info = parseLinkPage(base, html);
    expect(info, isNotNull);
    expect(info!.title, "Tom & Jerry 's 'x'");
  });

  test('title with encoded script tags contains no < or >', () {
    final html = '<title>&lt;script&gt;alert(1)&lt;/script&gt;Hi</title>';
    final info = parseLinkPage(base, html);
    expect(info, isNotNull);
    expect(info!.title, contains('Hi'));
    expect(info.title, isNot(contains('<')));
    expect(info.title, isNot(contains('>')));
  });

  test('newlines and tabs collapsed in title', () {
    final html = '<title>\n  Hello\t\tWorld \n</title>';
    final info = parseLinkPage(base, html);
    expect(info, isNotNull);
    expect(info!.title, 'Hello World');
  });

  test('long fields are truncated to limits', () {
    final longTitle = 'a' * 500;
    final longDesc = 'b' * 1000;
    final longSite = 'c' * 300;
    final html =
        '''
      <meta property="og:title" content="$longTitle">
      <meta property="og:description" content="$longDesc">
      <meta property="og:site_name" content="$longSite">
    ''';
    final info = parseLinkPage(base, html);
    expect(info, isNotNull);
    expect(info!.title.length, inInclusiveRange(1, 200));
    expect(info.title, startsWith('a' * 150));
    expect(info.description!.length, lessThanOrEqualTo(400));
    expect(info.description, startsWith('b' * 300));
    expect(info.site!.length, lessThanOrEqualTo(100));
    expect(info.site, startsWith('c' * 80));
  });

  test('image null for javascript: and data: URLs', () {
    final jsHtml =
        '<title>T</title><meta property="og:image" content="javascript:alert(1)">';
    final dataHtml =
        '<title>T</title><meta property="og:image" content="data:image/png;base64,AAAA">';
    final jsInfo = parseLinkPage(base, jsHtml);
    final dataInfo = parseLinkPage(base, dataHtml);
    expect(jsInfo, isNotNull);
    expect(jsInfo!.image, isNull);
    expect(dataInfo, isNotNull);
    expect(dataInfo!.image, isNull);
  });

  test('content before property, single quotes, upper-case tags', () {
    final html = "<META PROPERTY='og:title' CONTENT='Upper Title'>";
    final info = parseLinkPage(base, html);
    expect(info, isNotNull);
    expect(info!.title, 'Upper Title');
  });

  test('og:title after 300000 chars results in null', () {
    final padding = 'x' * 300001;
    final html = '$padding<meta property="og:title" content="Late Title">';
    final info = parseLinkPage(base, html);
    expect(info, isNull);
  });

  test('hostile input does not throw', () {
    final unterminated = '<meta property="og:title" content="abc';
    final garbage = '<<<>>>""\'\'';
    final manyLess = String.fromCharCodes(
      List.filled(1048576, '<'.codeUnitAt(0)),
    );
    final nested = 'nested "quotes" test';
    final html = '$unterminated$garbage$manyLess$nested';
    expect(() => parseLinkPage(base, html), returnsNormally);
  });

  test('control characters removed from og:title', () {
    final html = '<meta property="og:title" content="Title\u0000\u0007\u001b">';
    final info = parseLinkPage(base, html);
    expect(info, isNotNull);
    expect(info!.title, 'Title');
  });

  test('empty html returns null', () {
    final info = parseLinkPage(base, '');
    expect(info, isNull);
  });

  test('description falls back to meta name=description', () {
    final info = parseLinkPage(
      base,
      '<title>T</title><meta name="description" content="Plain desc">',
    );
    expect(info!.description, 'Plain desc');
  });

  test('og wins over twitter and plain tags', () {
    final info = parseLinkPage(
      base,
      '<title>Plain</title><meta name="twitter:title" content="Tw">'
      '<meta property="og:title" content="Og">',
    );
    expect(info!.title, 'Og');
  });

  test('raw tag markup inside a value never survives as < or >', () {
    final info = parseLinkPage(
      base,
      '<meta property="og:title" content="a &lt;b&gt; c">'
      '<meta property="og:description" content="x &#60;img src=1&#62; y">',
    );
    expect(info!.title, isNot(contains('<')));
    expect(info.title, isNot(contains('>')));
    expect(info.description, isNot(contains('<')));
    expect(info.description, isNot(contains('>')));
  });

  test('absolute og:image on another host is kept as given', () {
    final info = parseLinkPage(
      base,
      '<title>T</title><meta property="og:image" content="https://cdn.example.net/p.jpg">',
    );
    expect(info!.image, Uri.parse('https://cdn.example.net/p.jpg'));
  });

  test('TARGET L1: invisible format characters are stripped from the text', () {
    final info = parseLinkPage(
      base,
      '<meta property="og:title" content="pay​pal‮⁦﻿">'
      '<meta property="og:description" content="d‏e">'
      '<meta property="og:site_name" content="s⁩ite">',
    );
    expect(info!.title, 'paypal');
    expect(info.description, 'de');
    expect(info.site, 'site');
  });
}
