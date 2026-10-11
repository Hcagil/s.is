// The sandboxed web view that plays an embed (webview_flutter 4.14.1), run
// against a fake web view platform: the platform interface is the boundary,
// so the fake answers exactly what the plugin's own platform side would
// hand to the app (navigation requests, HTTP errors, load errors, permission
// requests) and records every setting the app applies.
//
// Needs a device (not reachable through the platform interface): the
// Android-only settings (file/content access off, mixed content never,
// geolocation off) and the iOS WebKit creation parameters, actual playback,
// and that clearing web data really empties the store.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/webview_video_embed.dart';
import 'package:sis/features/chat/domain/video_embed.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// Every call the app made on the platform side, in order.
final log = <String>[];
final loads = <LoadRequestParams>[];
Nav? nav;
void Function(PlatformWebViewPermissionRequest)? permissionHandler;

class _Platform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _Controller(params);
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => nav = Nav(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _Widget(params);
  @override
  PlatformWebViewCookieManager createPlatformCookieManager(
    PlatformWebViewCookieManagerCreationParams params,
  ) => _Cookies(params);
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();

  Future<void> _rec(String what) async => log.add(what);

  @override
  Future<void> loadRequest(LoadRequestParams params) {
    loads.add(params);
    return _rec('loadRequest ${params.uri}');
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) =>
      _rec('loadHtmlString');
  @override
  Future<void> loadFile(String absoluteFilePath) => _rec('loadFile');
  @override
  Future<void> loadFlutterAsset(String key) => _rec('loadFlutterAsset');
  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) =>
      _rec('setJavaScriptMode ${mode.name}');
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) =>
      _rec('addJavaScriptChannel ${params.name}');
  @override
  Future<void> runJavaScript(String javaScript) => _rec('runJavaScript');
  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    log.add('runJavaScriptReturningResult');
    return '';
  }

  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate h) =>
      _rec('setPlatformNavigationDelegate');
  @override
  Future<void> clearCache() => _rec('clearCache');
  @override
  Future<void> clearLocalStorage() => _rec('clearLocalStorage');
  @override
  Future<void> setOnPlatformPermissionRequest(
    void Function(PlatformWebViewPermissionRequest request) onPermissionRequest,
  ) {
    permissionHandler = onPermissionRequest;
    return _rec('setOnPlatformPermissionRequest');
  }

  @override
  Future<void> setBackgroundColor(Color color) => _rec('setBackgroundColor');
  @override
  Future<void> setUserAgent(String? userAgent) => _rec('setUserAgent');
  @override
  Future<void> enableZoom(bool enabled) => _rec('enableZoom $enabled');
  @override
  Future<void> setOnConsoleMessage(
    void Function(JavaScriptConsoleMessage) onConsoleMessage,
  ) => _rec('setOnConsoleMessage');
  @override
  Future<void> setOverScrollMode(WebViewOverScrollMode mode) =>
      _rec('setOverScrollMode');
  @override
  Future<void> setVerticalScrollBarEnabled(bool enabled) =>
      _rec('setVerticalScrollBarEnabled');
  @override
  Future<void> setHorizontalScrollBarEnabled(bool enabled) =>
      _rec('setHorizontalScrollBarEnabled');
  @override
  bool supportsSetScrollBarsEnabled() => true;
}

class Nav extends PlatformNavigationDelegate {
  Nav(super.params) : super.implementation();
  NavigationRequestCallback? onNavigationRequest;
  HttpResponseErrorCallback? onHttpError;
  WebResourceErrorCallback? onWebResourceError;
  PageEventCallback? onPageFinished;
  PageEventCallback? onPageStarted;

  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback c) async =>
      onNavigationRequest = c;
  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback c) async =>
      onHttpError = c;
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback c) async =>
      onWebResourceError = c;
  @override
  Future<void> setOnPageFinished(PageEventCallback c) async =>
      onPageFinished = c;
  @override
  Future<void> setOnPageStarted(PageEventCallback c) async => onPageStarted = c;
  @override
  Future<void> setOnProgress(ProgressCallback c) async {}
  @override
  Future<void> setOnUrlChange(UrlChangeCallback c) async {}
  @override
  Future<void> setOnHttpAuthRequest(HttpAuthRequestCallback c) async {}
  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback c) async {}
}

class _Widget extends PlatformWebViewWidget {
  _Widget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) =>
      const SizedBox.expand(key: ValueKey('platform-web-view'));
}

class _Cookies extends PlatformWebViewCookieManager {
  _Cookies(super.params) : super.implementation();
  @override
  Future<bool> clearCookies() async {
    log.add('clearCookies');
    return true;
  }

  @override
  Future<void> setCookie(WebViewCookie cookie) async => log.add('setCookie');
}

class _Permission extends PlatformWebViewPermissionRequest {
  _Permission() : super(types: {WebViewPermissionResourceType.camera});
  final answers = <String>[];
  @override
  Future<void> grant() async => answers.add('grant');
  @override
  Future<void> deny() async => answers.add('deny');
}

const _yt = 'https://youtu.be/dQw4w9WgXcQ';

void main() {
  late VideoEmbed embed;
  late int loaded;
  late List<VideoRefusal> refusals;
  late List<Uri> external;

  setUp(() {
    WebViewPlatform.instance = _Platform();
    log.clear();
    loads.clear();
    nav = null;
    permissionHandler = null;
    embed = videoEmbedFor(Uri.parse(_yt))!;
    loaded = 0;
    refusals = [];
    external = [];
  });

  Future<void> mount(WidgetTester t, [VideoEmbed? e]) async {
    await t.pumpWidget(
      MaterialApp(
        home: webViewVideoEmbed(
          VideoEmbedViewSpec(
            embed: e ?? embed,
            onLoaded: () => loaded++,
            onRefused: refusals.add,
            onExternal: external.add,
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump();
  }

  FutureOr<NavigationDecision> go(String url, {required bool main}) =>
      nav!.onNavigationRequest!(NavigationRequest(url: url, isMainFrame: main));

  group('settings', () {
    testWidgets('init does not throw and loads the embed url once, with the '
        'embed referer', (t) async {
      await mount(t);
      expect(t.takeException(), isNull);
      expect(loads, hasLength(1));
      expect(loads.single.uri, embed.url);
      expect(
        {
          for (final h in loads.single.headers.entries)
            h.key.toLowerCase(): h.value,
        }['referer'],
        embed.referer,
      );
    });

    testWidgets('JavaScript is on; no JavaScript bridge to the app', (t) async {
      await mount(t);
      expect(log, contains('setJavaScriptMode unrestricted'));
      expect(log.where((c) => c.startsWith('addJavaScriptChannel')), isEmpty);
      expect(log.where((c) => c.startsWith('loadHtmlString')), isEmpty);
      expect(log.where((c) => c.startsWith('loadFile')), isEmpty);
    });

    testWidgets('web data is wiped before the first load', (t) async {
      await mount(t);
      final first = log.indexWhere((c) => c.startsWith('loadRequest'));
      expect(first, isNonNegative);
      for (final wipe in ['clearCache', 'clearLocalStorage', 'clearCookies']) {
        final i = log.indexOf(wipe);
        expect(i, isNonNegative, reason: '$wipe at init');
        expect(i, lessThan(first), reason: '$wipe before the load: $log');
      }
    });

    testWidgets('a page asking for camera or microphone is denied', (t) async {
      await mount(t);
      expect(permissionHandler, isNotNull);
      final ask = _Permission();
      permissionHandler!(ask);
      await t.pump();
      expect(ask.answers, ['deny']);
      expect(t.takeException(), isNull);
    });

    testWidgets('closing wipes cache, local storage and cookies', (t) async {
      await mount(t);
      log.clear();
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      await t.pump();
      expect(
        log,
        containsAll(['clearCache', 'clearLocalStorage', 'clearCookies']),
      );
    });
  });

  group('navigation', () {
    testWidgets('the embed itself loads as the main frame', (t) async {
      await mount(t);
      expect(
        await go(embed.url.toString(), main: true),
        NavigationDecision.navigate,
      );
      expect(external, isEmpty);
    });

    testWidgets('a sub frame on the site domains loads', (t) async {
      await mount(t);
      for (final u in [
        'https://www.youtube.com/s/player/x.html',
        'https://www.youtube-nocookie.com/embed/x',
      ]) {
        expect(
          await go(u, main: false),
          NavigationDecision.navigate,
          reason: u,
        );
      }
      expect(external, isEmpty);
    });

    testWidgets('a main frame leaving the embed is cancelled and reported '
        'once as outside', (t) async {
      await mount(t);
      for (final u in [
        'https://evil.io/landing',
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'http://evil.io/plain',
      ]) {
        expect(await go(u, main: true), NavigationDecision.prevent, reason: u);
      }
      expect(external, [
        Uri.parse('https://evil.io/landing'),
        Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
        Uri.parse('http://evil.io/plain'),
      ]);
    });

    testWidgets('anything else is cancelled silently', (t) async {
      await mount(t);
      for (final (u, main) in [
        ('https://evil.io/frame', false),
        ('http://www.youtube.com/embed/x', false),
        ('intent://scan/#Intent;scheme=zxing;end', true),
        ('file:///etc/passwd', true),
        ('javascript:alert(1)', true),
        ('market://details?id=x', true),
        ('data:text/html,hi', false),
      ]) {
        expect(await go(u, main: main), NavigationDecision.prevent, reason: u);
      }
      expect(external, isEmpty);
      expect(refusals, isEmpty);
    });
  });

  group('refusals', () {
    HttpResponseError httpError(String url, int status) => HttpResponseError(
      request: WebResourceRequest(uri: Uri.parse(url)),
      response: WebResourceResponse(uri: Uri.parse(url), statusCode: status),
    );

    for (final (status, refusal) in [
      (401, VideoRefusal.login),
      (403, VideoRefusal.isPrivate),
      (404, VideoRefusal.deleted),
      (410, VideoRefusal.deleted),
      (451, VideoRefusal.region),
      (500, VideoRefusal.other),
    ]) {
      testWidgets('HTTP $status on the embed is $refusal', (t) async {
        await mount(t);
        nav!.onHttpError!(httpError(embed.url.toString(), status));
        await t.pump();
        expect(refusals, [refusal]);
      });
    }

    testWidgets('an HTTP error on another resource is not a refusal', (
      t,
    ) async {
      await mount(t);
      nav!.onHttpError?.call(
        httpError('https://www.youtube.com/api/stats/qoe?x=1', 404),
      );
      nav!.onHttpError?.call(
        httpError('https://evil.io/embed/dQw4w9WgXcQ', 403),
      );
      await t.pump();
      expect(refusals, isEmpty);
    });

    testWidgets('a main-frame load error is a refusal; a sub-resource error '
        'is not', (t) async {
      await mount(t);
      nav!.onWebResourceError!(
        const WebResourceError(
          errorCode: -2,
          description: 'net::ERR_NAME_NOT_RESOLVED',
          isForMainFrame: false,
          url: 'https://i.ytimg.com/vi/x.jpg',
        ),
      );
      await t.pump();
      expect(refusals, isEmpty);
      nav!.onWebResourceError!(
        WebResourceError(
          errorCode: -2,
          description: 'net::ERR_NAME_NOT_RESOLVED',
          isForMainFrame: true,
          url: embed.url.toString(),
        ),
      );
      await t.pump();
      expect(refusals, hasLength(1));
    });
  });
}
