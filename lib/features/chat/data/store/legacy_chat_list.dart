import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Deletes the old chat_list.json snapshot (and a leftover .part file) from the app support directory; the chat list now lives in the encrypted store. Never throws.
Future<void> deleteLegacyChatList({
  Future<Directory> Function()? supportDir,
}) async {
  try {
    final dir = await (supportDir ?? getApplicationSupportDirectory)();
    for (final name in ['chat_list.json', 'chat_list.json.part']) {
      final f = File('${dir.path}/$name');
      if (await f.exists()) await f.delete();
    }
  } catch (_) {
    // Nothing to delete, or the platform channel is unavailable.
  }
}
