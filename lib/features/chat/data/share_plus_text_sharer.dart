import 'dart:developer';

import 'package:share_plus/share_plus.dart';

import '../domain/text_sharer.dart';

/// [TextSharer] that opens the phone's share sheet with the text.
final class SharePlusTextSharer implements TextSharer {
  /// Creates the sharer.
  const SharePlusTextSharer();

  @override
  Future<void> share(String text) async {
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (e) {
      log('Sharing text failed: ${e.runtimeType}', name: 'sis.chat');
    }
  }
}
