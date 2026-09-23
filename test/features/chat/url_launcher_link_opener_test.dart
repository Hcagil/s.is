// The link opener's guard, written from the contract. Nothing is launched:
// the platform channel url_launcher talks to is answered here, so the test
// sees exactly what would have reached the OS, and whether anything did.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/url_launcher_link_opener.dart';

const _channel = MethodChannel('plugins.flutter.io/url_launcher');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Every call that reached the platform, in order.
  late List<MethodCall> reached;

  /// What the platform does with a launch.
  late Future<Object?> Function(MethodCall) platform;

  setUp(() {
    reached = [];
    platform = (_) async => true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) {
          reached.add(call);
          return platform(call);
        });
  });

  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null),
  );

  const opener = UrlLauncherLinkOpener();

  test('a non-web scheme is refused before anything is launched', () async {
    for (final link in [
      'javascript:alert(1)',
      'mailto:ali@example.com',
      'intent://scan/#Intent;scheme=zxing;end',
      'ftp://files.example.com/a.zip',
      'file:///etc/passwd',
      'tel:+905551112233',
      'market://details?id=com.esd.sis',
      'data:text/html,hi',
      '//example.com/no-scheme',
      'example.com',
    ]) {
      expect(await opener.open(Uri.parse(link)), isFalse, reason: link);
    }
    expect(reached, isEmpty, reason: 'a refused scheme reached the platform');
  });

  test('an http(s) link is launched in an external application', () async {
    expect(await opener.open(Uri.parse('https://example.com/a?b=1')), isTrue);
    expect(await opener.open(Uri.parse('HTTP://Example.com')), isTrue);

    expect(reached, hasLength(2));
    final first = reached.first.arguments as Map;
    expect(reached.first.method, 'launch');
    expect(first['url'], 'https://example.com/a?b=1');
    expect(
      first['useWebView'],
      isFalse,
      reason: 'a link must open in the browser app, not inside ours',
    );
    expect(first['useSafariVC'], isFalse);
    expect(
      first['universalLinksOnly'],
      isFalse,
      reason: 'a web link with no app to claim it must still open',
    );
  });

  test('the platform declining is reported as false', () async {
    platform = (_) async => false;
    expect(await opener.open(Uri.parse('https://example.com')), isFalse);
    expect(reached, hasLength(1));
  });

  test('a platform that throws is false, never an exception', () async {
    platform = (_) async =>
        throw PlatformException(code: 'ACTIVITY_NOT_FOUND', message: 'none');
    expect(await opener.open(Uri.parse('https://example.com')), isFalse);

    platform = (_) async => throw StateError('channel torn down');
    expect(await opener.open(Uri.parse('https://example.com')), isFalse);
  });
}
