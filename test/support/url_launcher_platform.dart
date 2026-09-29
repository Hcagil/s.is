import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// One launch that reached the platform.
typedef Launch = ({String url, PreferredLaunchMode mode});

/// url_launcher's platform side: records what would have reached the OS and
/// answers as the OS would. [handles] decides whether an app claims a URL
/// (false = nothing installed for that scheme, as `market://` on a phone
/// without Play); it answers `canLaunch` and `launchUrl` alike.
class FakeUrlLauncherPlatform extends UrlLauncherPlatform {
  final launches = <Launch>[];
  final canLaunchAsked = <String>[];
  bool Function(String url) handles = (_) => true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async {
    canLaunchAsked.add(url);
    return handles(url);
  }

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launches.add((url: url, mode: options.mode));
    return handles(url);
  }

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) =>
      throw StateError('legacy launch() used; url_launcher 6 calls launchUrl');

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;
}
