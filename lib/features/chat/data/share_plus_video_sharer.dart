import 'dart:developer';

import 'package:share_plus/share_plus.dart';

import '../domain/video.dart';

/// [VideoSharer] that opens the phone's share sheet with the video file.
final class SharePlusVideoSharer implements VideoSharer {
  /// Creates the sharer.
  const SharePlusVideoSharer();

  @override
  Future<void> share(String path) async {
    try {
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
    } catch (e) {
      log('Sharing a video failed: ${e.runtimeType}', name: 'sis.video');
    }
  }
}
