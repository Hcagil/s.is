import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import '../domain/video_embed.dart';

/// A sandboxed WebView that shows ONE official video embed page.
Widget webViewVideoEmbed(VideoEmbedViewSpec spec) =>
    _EmbedWebView(key: ValueKey(spec.embed.url), spec: spec);

/// Sandboxed web view for a single video embed.
class _EmbedWebView extends StatefulWidget {
  /// Creates the widget with the given spec.
  const _EmbedWebView({super.key, required this.spec});

  /// The video embed specification to load.
  final VideoEmbedViewSpec spec;

  @override
  State<_EmbedWebView> createState() => _EmbedWebViewState();
}

class _EmbedWebViewState extends State<_EmbedWebView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();

    final params = WebViewPlatform.instance is WebKitWebViewPlatform
        ? WebKitWebViewControllerCreationParams(
            allowsInlineMediaPlayback: true,
            mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
          )
        : const PlatformWebViewControllerCreationParams();

    _controller = WebViewController.fromPlatformCreationParams(
      params,
      onPermissionRequest: (request) => request.deny(),
    );

    // Sandboxed WebView settings.
    _controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(false)
      ..setBackgroundColor(const Color(0xFF000000))
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: _onNavigation,
          onPageFinished: (_) => widget.spec.onLoaded(),
          onHttpError: (HttpResponseError error) {
            final uri = error.request?.uri;
            final code = error.response?.statusCode;
            if (uri == null || code == null) return;
            if (uri.host != widget.spec.embed.url.host ||
                uri.path != widget.spec.embed.url.path) {
              return;
            }
            widget.spec.onRefused(refusalForStatus(code));
          },
          onWebResourceError: (WebResourceError error) {
            if (error.isForMainFrame == false) return;
            widget.spec.onRefused(VideoRefusal.other);
          },
        ),
      );

    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      platform.setAllowFileAccess(false);
      platform.setAllowContentAccess(false);
      platform.setGeolocationEnabled(false);
      platform.setMixedContentMode(MixedContentMode.neverAllow);
      platform.setMediaPlaybackRequiresUserGesture(false);
    }

    // Wipe anything a killed app left behind before the first load.
    unawaited(_controller.clearCache());
    unawaited(_controller.clearLocalStorage());
    unawaited(WebViewCookieManager().clearCookies());

    unawaited(
      _controller.loadRequest(
        widget.spec.embed.url,
        headers: {
          if (widget.spec.embed.referer != null)
            'Referer': widget.spec.embed.referer!,
        },
      ),
    );
  }

  NavigationDecision _onNavigation(NavigationRequest request) {
    final uri = Uri.tryParse(request.url);
    if (uri != null &&
        videoEmbedAllows(
          widget.spec.embed,
          uri,
          mainFrame: request.isMainFrame,
        )) {
      return NavigationDecision.navigate;
    }
    if (request.isMainFrame &&
        uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http')) {
      widget.spec.onExternal(uri);
    }
    return NavigationDecision.prevent;
  }

  @override
  void dispose() {
    unawaited(_controller.clearCache());
    unawaited(_controller.clearLocalStorage());
    unawaited(WebViewCookieManager().clearCookies());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
