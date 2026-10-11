import 'dart:async';
import 'dart:convert';
import 'dart:io' show InternetAddress;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../domain/link_page.dart';
import '../domain/link_preview.dart';
import '../domain/link_preview_fetcher.dart';

/// Reads web pages and extracts link previews from them.
final class HttpLinkPreviewFetcher implements LinkPreviewFetcher {
  HttpLinkPreviewFetcher(
    this._client, {
    Future<Uint8List?> Function(Uint8List bytes)? shrink,
    this.timeout = const Duration(seconds: 6),
    Future<List<InternetAddress>> Function(String host)? lookup,
  }) : _shrink = shrink ?? ((_) async => null),
       _lookup = lookup ?? InternetAddress.lookup;

  final http.Client _client;
  final Future<Uint8List?> Function(Uint8List bytes) _shrink;
  final Future<List<InternetAddress>> Function(String host) _lookup;

  /// Longest wait for the page; the picture gets half of it on its own.
  final Duration timeout;

  @override
  Future<LinkPreviewDraft?> fetch(Uri url) async {
    try {
      return await _fetch(url);
    } catch (_) {
      return null;
    }
  }

  Future<LinkPreviewDraft?> _fetch(Uri url) async {
    if (url.scheme != 'http' && url.scheme != 'https') return null;
    if (url.host.isEmpty) return null;
    final page = await _read(
      url,
      maxBytes: 300000,
      accept: 'text/html,application/xhtml+xml',
      truncate: true,
      type: 'html',
      budget: timeout,
    );
    if (page == null) return null;
    final html = utf8.decode(page, allowMalformed: true);
    final info = parseLinkPage(url, html);
    if (info == null) return null;

    Uint8List? jpeg;
    if (info.image != null) {
      try {
        final raw = await _read(
          info.image!,
          maxBytes: 3000000,
          accept: 'image/*',
          truncate: false,
          type: 'image/',
          budget: Duration(microseconds: timeout.inMicroseconds ~/ 2),
        );
        if (raw != null) jpeg = await _shrink(raw);
      } catch (_) {
        // A picture that fails or stalls never costs the card.
      }
    }

    return LinkPreviewDraft(
      preview: LinkPreview(
        url: url,
        title: info.title,
        description: info.description,
        site: info.site,
        video: isVideoHost(url),
      ),
      image: jpeg,
    );
  }

  /// Reads [uri] (following up to 5 redirects by hand, checking every hop)
  /// with a max of [maxBytes] inside [budget]; returns the bytes or null.
  Future<Uint8List?> _read(
    Uri uri, {
    required int maxBytes,
    required String accept,
    required bool truncate,
    required String type,
    required Duration budget,
  }) async {
    final sw = Stopwatch()..start();
    for (var hop = 0; hop < 6; hop++) {
      if (!await _allowed(uri)) return null;
      Duration remaining() {
        final left = budget - sw.elapsed;
        if (left <= Duration.zero) throw TimeoutException('timeout', budget);
        return left;
      }

      final request = http.Request('GET', uri);
      request.headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36 SISLinkPreview';
      request.headers['Accept'] = accept;
      request.headers['Accept-Language'] = 'en,tr;q=0.8';
      request.followRedirects = false;

      final response = await _client.send(request).timeout(remaining());

      if (response.statusCode >= 300 && response.statusCode <= 399) {
        final location = response.headers['location'];
        if (location == null) return null;
        unawaited(response.stream.listen(null).cancel());
        final next = uri.resolve(location);
        if (hop == 5) return null;
        if (uri.scheme == 'https' && next.scheme != 'https') return null;
        uri = next;
        continue;
      }

      if (response.statusCode < 200 || response.statusCode > 299) return null;

      final contentType = response.headers['content-type'];
      final ok = contentType == null ? truncate : contentType.contains(type);
      if (!ok) {
        unawaited(response.stream.listen(null).cancel());
        return null;
      }

      final bytes = BytesBuilder(copy: false);
      var total = 0;
      final it = StreamIterator(response.stream);
      try {
        while (await it.moveNext().timeout(remaining())) {
          final chunk = it.current;
          if (total + chunk.length > maxBytes) {
            if (!truncate) return null;
            bytes.add(chunk.sublist(0, maxBytes - total));
            break;
          }
          bytes.add(chunk);
          total += chunk.length;
          if (total >= maxBytes) break;
        }
      } finally {
        // Also runs on timeout: a stalled body is cancelled, not left open.
        await it.cancel();
      }
      return bytes.toBytes();
    }
    return null;
  }

  Future<bool> _allowed(Uri u) async {
    if (u.scheme != 'http' && u.scheme != 'https') return false;
    final host = u.host.toLowerCase();
    if (host.isEmpty || host == 'localhost' || host.endsWith('.localhost')) {
      return false;
    }
    final ip = InternetAddress.tryParse(host);
    if (ip != null) return !_private(ip);
    try {
      final list = await _lookup(host);
      return !list.any(_private);
    } catch (_) {
      // A failed lookup means the http client cannot connect either.
      return true;
    }
  }

  /// Loopback, private, link-local, CGNAT, ULA, multicast, documentation and
  /// other special ranges.
  static bool _private(InternetAddress a) {
    final b = a.rawAddress;
    if (b.length == 4) {
      if (b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224) return true;
      if (b[0] == 169 && b[1] == 254) return true;
      if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
      if (b[0] == 192 && b[1] == 168) return true;
      if (b[0] == 100 && b[1] >= 64 && b[1] <= 127) return true;
      if (b[0] == 192 && b[1] == 0 && (b[2] == 0 || b[2] == 2)) return true;
      if (b[0] == 198 && (b[1] == 18 || b[1] == 19)) return true;
      if (b[0] == 198 && b[1] == 51 && b[2] == 100) return true;
      if (b[0] == 203 && b[1] == 0 && b[2] == 113) return true;
      return false;
    }
    if (b.length != 16) return true;
    if (b.sublist(0, 15).every((x) => x == 0) && b[15] <= 1) return true;
    if ((b[0] & 0xfe) == 0xfc) return true;
    if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return true;
    if (b[0] == 0xff) return true;
    if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) {
      return true;
    }
    if (b.sublist(0, 10).every((x) => x == 0) &&
        b[10] == 0xff &&
        b[11] == 0xff) {
      return _private(
        InternetAddress.fromRawAddress(Uint8List.fromList(b.sublist(12))),
      );
    }
    return false;
  }
}
