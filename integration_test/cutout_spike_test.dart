// Emulator probe: the subject-segmentation model downloads through Play services and returns a mask.
// Needs a google_apis_playstore image started with -gpu guest (swiftshader_indirect crashes inside ML Kit).
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

  testWidgets('cutout spike feasibility probe', (WidgetTester tester) async {
    // 1. Check support
    final Stopwatch swSupport = Stopwatch()..start();
    final bool supported =
        await channel.invokeMethod<bool>('cutoutSupported') ?? false;
    swSupport.stop();
    // ignore: avoid_print
    print(
      'SPIKE supported=$supported elapsed_ms=${swSupport.elapsedMilliseconds}',
    );

    // 2. Download photo
    final Stopwatch swDownload = Stopwatch()..start();
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
    swDownload.stop();
    // ignore: avoid_print
    print(
      'SPIKE photo_bytes=${photoBytes.length} elapsed_ms=${swDownload.elapsedMilliseconds}',
    );

    // 3. Poll for mask
    const maxDuration = Duration(minutes: 6);
    const interval = Duration(seconds: 10);
    final Stopwatch swPoll = Stopwatch()..start();
    Uint8List? mask;
    int attempt = 0;
    while (swPoll.elapsed < maxDuration) {
      attempt++;
      final Stopwatch swCall = Stopwatch()..start();
      final Uint8List? result = await channel.invokeMethod<Uint8List?>(
        'cutoutMask',
        {'bytes': photoBytes},
      );
      swCall.stop();
      if (result != null && result.isNotEmpty) {
        mask = result;
        // ignore: avoid_print
        print(
          'SPIKE try=$attempt mask_bytes=${result.length} elapsed_ms=${swPoll.elapsedMilliseconds}',
        );
        break;
      }
      // ignore: avoid_print
      print(
        'SPIKE try=$attempt mask=null elapsed_ms=${swCall.elapsedMilliseconds}',
      );
      await Future<void>.delayed(interval);
    }
    swPoll.stop();

    // 4. Expect mask
    expect(mask, isNotNull, reason: 'model never became ready in 6 min');
    expect(mask!.isNotEmpty, isTrue, reason: 'model returned empty mask');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
