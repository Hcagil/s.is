// Runs only on the iOS simulator in CI (.github/workflows/ci.yml, job ios):
// the real light_compressor_v2 getMediaInfo, i.e. AVFoundation, reading the
// copy prepareVideoSource stores. The bug: a picked iPhone video was copied
// without an extension and never sent. (b) records whether AVFoundation can
// read the same bytes with no extension; its verdict line is printed for the
// CI log, prefixed SIS-PROOF.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:light_compressor_v2/light_compressor_v2.dart' as lc;
import 'package:path_provider/path_provider.dart';
import 'package:sis/features/chat/data/flutter_device_files.dart';
import 'package:sis/features/chat/data/video_source_prep.dart';
import 'package:sis/features/chat/domain/video.dart';

import 'fixtures/sample_mov.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final files = FlutterDeviceFiles(root: getTemporaryDirectory);
  final compressor = lc.LightCompressor();

  void readableSample(String label, VideoSource r) {
    // ignore: avoid_print
    print(
      'SIS-PROOF ($label) source=${r.path} durationMs=${r.durationMs} '
      '${r.width}x${r.height}',
    );
    expect(r.durationMs, inInclusiveRange(1500, 2500));
    expect({r.width, r.height}, {160, 120});
  }

  test('(a) extension "MOV": the copy is source.mov and readable', () async {
    final result = await prepareVideoSource(
      files: files,
      compressor: compressor,
      name: 'IMG_0001.MOV',
      bytes: Stream.value(sampleMov),
      extension: 'MOV',
    );
    expect(result.tooLong, isFalse);
    final source = result.source;
    expect(source, isNotNull, reason: 'AVFoundation could not read source.mov');
    expect(source!.path.split('/').last, 'source.mov');
    readableSample('a', source);
  });

  test(
    '(c) no extension given: on iOS the copy is source.mov and readable',
    () async {
      final result = await prepareVideoSource(
        files: files,
        compressor: compressor,
        name: 'IMG_0001',
        bytes: Stream.value(sampleMov),
      );
      final source = result.source;
      expect(source, isNotNull);
      expect(source!.path.split('/').last, 'source.mov');
      readableSample('c', source);
    },
  );

  // The cause, recorded rather than assumed: the same bytes under a name with
  // no extension, probed by the same real getMediaInfo.
  test(
    '(b) the same file with NO extension: record what AVFoundation does',
    () async {
      final dir = await Directory(
        '${(await getTemporaryDirectory()).path}/sis-proof-b',
      ).create(recursive: true);
      final bare = File('${dir.path}/source');
      await bare.writeAsBytes(sampleMov);
      String verdict;
      try {
        final info = await compressor
            .getMediaInfo(bare.path)
            .timeout(const Duration(seconds: 30));
        final readable =
            info.duration != null &&
            info.duration! > Duration.zero &&
            info.width != null &&
            info.height != null;
        verdict = readable
            ? 'READABLE (extension was NOT the cause): '
                  'duration=${info.duration} ${info.width}x${info.height}'
            : 'UNREADABLE (extension IS the cause): '
                  'duration=${info.duration} ${info.width}x${info.height}';
      } catch (e) {
        verdict = 'UNREADABLE (extension IS the cause): ${e.runtimeType}: $e';
      } finally {
        await dir.delete(recursive: true);
      }
      // ignore: avoid_print
      print('SIS-PROOF (b) extensionless ${bare.path}: $verdict');
      expect(verdict, isNotEmpty);
    },
  );
}
