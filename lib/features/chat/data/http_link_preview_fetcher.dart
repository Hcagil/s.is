import 'dart:async';
import 'dart:convert';
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
  }) : _shrink = shrink ?? ((_) async => null);

  final http.Client _client;
  final Future<Uint8List?> Function(Uint8List bytes) _shrink;

  /// Longest wait for the page and for its picture.
  final Duration timeout;

  @override
  Future<LinkPreviewDraft?> fetch(Uri url) async {
    try {
      return await _fetch(url).timeout(timeout);
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
    );
    if (page == null) return null;
    final html = utf8.decode(page, allowMalformed: true);
    final info = parseLinkPage(url, html);
    if (info == null) return null;

    Uint8List? jpeg;
    if (info.image != null) {
      final raw = await _read(
        info.image!,
        maxBytes: 3000000,
        accept: 'image/*',
        truncate: false,
        type: 'image/',
      );
      if (raw != null) {
        jpeg = await _shrink(raw);
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

  /// Reads [uri] with a max of [maxBytes], returns the bytes or null.
  Future<Uint8List?> _read(
    Uri uri, {
    required int maxBytes,
    required String accept,
    required bool truncate,
    required String type,
  }) async {
    final request = http.Request('GET', uri);
    request.headers['User-Agent'] = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Mobile Safari/537.36 SISLinkPreview';
    request.headers['Accept'] = accept;
    request.headers['Accept-Language'] = 'en,tr;q=0.8';
    request.followRedirects = true;
    request.maxRedirects = 5;

    final response = await _client.send(request).timeout(timeout);

    if (response.statusCode < 200 || response.statusCode > 299) return null;

    final contentType = response.headers['content-type'];
    final ok = contentType == null ? truncate : contentType.contains(type);
    if (!ok) {
      return null;
    }

    final bytes = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in response.stream) {
      if (total + chunk.length > maxBytes) {
        if (!truncate) return null;
        bytes.add(chunk.sublist(0, maxBytes - total));
        break;
      }
      bytes.add(chunk);
      total += chunk.length;
      if (total >= maxBytes) break;
    }

    return bytes.toBytes();
  }
}
