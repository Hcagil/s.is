// Repro: ML Kit subject segmentation must never kill the app; cutoutMask returns null or a mask.
// On the google_apis_playstore emulator with the default GPU mode, about 3 boots in 8 the first
// inference fails and ML Kit's release then crashes the app on its own thread: RED until fixed.
// Keeps calling after the first mask, then checks the app still answers 20 s later.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const photoUrl =
      'https://upload.wikimedia.org/wikipedia/commons/thumb/a/a0/Pierre-Person.jpg/500px-Pierre-Person.jpg';
  const channel = MethodChannel('sis/external_picker');

  testWidgets('cutout crash repro', (WidgetTester tester) async {
    // 1. Check support
    final bool supported =
        await channel.invokeMethod<bool>('cutoutSupported') ?? false;
    // ignore: avoid_print
    print('REPRO supported=$supported');
    expect(supported, isTrue);

    // 2. Download photo
    final HttpClient client = HttpClient();
    Uint8List photoBytes;
    try {
      final request = await client.getUrl(Uri.parse(photoUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'sis-spike/1.0');
      final response = await request.close();
      if (response.statusCode != 200) {
        fail('Failed to download photo: HTTP ${response.statusCode}');
      }
      photoBytes = await consolidateHttpClientResponseBytes(response);
    } catch (e) {
      fail('Failed to download photo: $e');
    } finally {
      client.close();
    }

    // 3. Poll for mask
    const maxDuration = Duration(minutes: 6);
    const interval = Duration(seconds: 10);
    final Stopwatch swPoll = Stopwatch()..start();
    Uint8List? mask;
    int attempt = 0;
    int extraCalls = 0; // calls made after the first mask
    while (swPoll.elapsed < maxDuration) {
      attempt++;
      Uint8List? result;
      try {
        result = await channel.invokeMethod<Uint8List?>('cutoutMask', {
          'bytes': photoBytes,
        });
      } on PlatformException catch (e) {
        fail('cutoutMask threw instead of returning null: $e');
      }
      // ignore: avoid_print
      print(
        'REPRO try=$attempt result=${result == null ? 'null' : 'bytes:${result.length}'}',
      );
      if (mask != null) {
        extraCalls++;
        if (extraCalls == 5) break;
      } else if (result != null && result.isNotEmpty) {
        mask = result;
      }
      await Future<void>.delayed(interval);
    }

    // 4. Wait for potential late crash
    await Future<void>.delayed(const Duration(seconds: 20));

    // 5. Check app still alive
    final bool? alive = await channel.invokeMethod<bool>('cutoutSupported');
    expect(
      alive,
      isA<bool>(),
      reason: 'app process must still answer after the cut-out call',
    );
    // ignore: avoid_print
    print('REPRO alive_after_cutout=${alive == true}');

    // 6. Final mask report
    // ignore: avoid_print
    print('REPRO mask=${mask == null ? 'null' : 'bytes:${mask.length}'}');
  }, timeout: const Timeout(Duration(minutes: 9)));
}
