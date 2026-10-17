import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Removes the pre-store chat_list.json snapshot (it may hold message text)
/// and any .part; keeps the text-free push feed PushFeedWriter writes. Never
/// throws.
Future<void> deleteLegacyChatList({
  Future<Directory> Function()? supportDir,
}) async {
  try {
    final dir = await (supportDir ?? getApplicationSupportDirectory)();
    final f = File('${dir.path}/chat_list.json');
    if (await f.exists() && !await _isStrippedFeed(f)) await f.delete();
    final part = File('${dir.path}/chat_list.json.part');
    if (await part.exists()) await part.delete();
  } catch (_) {
    // Nothing to delete, or the platform channel is unavailable.
  }
}

/// True only for the new-format feed: version 1 and no entry holds message text.
Future<bool> _isStrippedFeed(File f) async {
  try {
    final decoded = jsonDecode(await f.readAsString());
    return decoded is Map &&
        decoded['v'] == 1 &&
        decoded['list'] is List &&
        (decoded['list'] as List).every(
          (e) => e is Map && e['lastMessage'] == null,
        );
  } catch (_) {
    return false;
  }
}
