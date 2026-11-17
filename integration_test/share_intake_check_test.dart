// Integration test for Android share intent intake via MainActivity.
// It waits for a real share intent (text + image) to be processed by SIS
// and verifies that the shared text and image path appear in the result.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const sharedText = 'sis lane share';
  const channel = MethodChannel('sis/share_intake');

  testWidgets('share intake check', (WidgetTester tester) async {
    // 1. Signal readiness to the host script.
    // ignore: avoid_print
    print('SHARE_CHECK_READY');

    // 2. Poll for the share result.
    const maxTries = 180;
    dynamic result;
    for (var i = 1; i <= maxTries; i++) {
      result = await channel.invokeMethod<dynamic>('take');
      if (result != null) {
        // ignore: avoid_print
        print('SHARE_CHECK take try=$i result=$result');
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    // 3. Verify that a share arrived.
    expect(result, isNotNull, reason: 'no share arrived in 180 s');

    // 4. Check contents of the result.
    final s = result.toString();
    expect(s, contains(sharedText), reason: 'shared text missing');
    expect(
      s,
      contains('/cache/shared/'),
      reason: 'shared image was not copied into cache/shared',
    );
  }, timeout: const Timeout(Duration(minutes: 4)));
}
