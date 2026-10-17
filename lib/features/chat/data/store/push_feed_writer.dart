import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../domain/conversation.dart';

const _schemaVersion = 1;

/// Writes chat_list.json, the plain-file feed the Android push code reads
/// picture paths from (InstantPush.avatarFor). It holds no message text. The
/// phone's own chat list lives in the encrypted store; this file is only that
/// feed.
final class PushFeedWriter {
  PushFeedWriter({Future<Directory> Function()? root})
    : _root = root ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _root;

  /// Bumped by [clear]; a [save] in flight when it changes lost the race and
  /// must not resurrect what clear() just erased.
  static int _epoch = 0;

  /// The current erase count, for a caller that must give up a write begun
  /// before a clear().
  int get epoch => _epoch;

  Future<File> _file() async => File('${(await _root()).path}/chat_list.json');

  Future<void> save(String ownerId, List<Conversation> conversations) async {
    final epoch = _epoch;
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      final body = jsonEncode({
        'v': _schemaVersion,
        'owner': ownerId,
        'list': [
          for (final c in conversations)
            {
              ...c.toJson(),
              'lastMessage': null,
              'lastMessageAt': null,
              'lastSenderId': null,
            },
        ],
      });
      // Written aside, then renamed: a half-written file is never read.
      final part = File('${file.path}.part');
      await part.writeAsString(body);
      if (_epoch != epoch) {
        // clear() ran while this write was in flight: the erase it performed
        // must win, not be undone by a save that started before it.
        await part.delete();
        return;
      }
      await part.rename(file.path);
      if (_epoch != epoch) {
        // clear() started before the rename landed and may have already run
        // its own deletes without seeing this file; undo what the rename
        // just (re)created so the erase still wins.
        await _tryDelete(file);
      }
    } catch (_) {
      // Best-effort: the next cold start just waits for the network instead.
      // No half-written temp file is left behind for a later write to trip
      // over.
      try {
        final part = File('${(await _file()).path}.part');
        if (await part.exists()) await part.delete();
      } catch (_) {
        // Nothing to delete, or nothing that can be.
      }
    }
  }

  Future<void> clear() async {
    _epoch++;
    final File file;
    try {
      file = await _file();
    } catch (_) {
      return; // Root itself is unavailable; nothing to clear.
    }
    final part = File('${file.path}.part');
    // Each delete is caught on its own, not one try/catch around all three:
    // a save's rename can land between any two of these (recreating
    // chat_list.json from `part`), and a throw from one delete must never
    // skip the ones after it. The trailing delete of `file` is what catches
    // a rename that lands after the first delete of `file` above but before
    // or during the delete of `part`.
    await _tryDelete(file);
    await _tryDelete(part);
    await _tryDelete(file);
  }

  Future<void> _tryDelete(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Already gone, or nothing that can be done about it.
    }
  }
}
