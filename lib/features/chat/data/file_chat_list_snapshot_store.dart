import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/chat_list_snapshot_store.dart';
import '../domain/conversation.dart';

const _schemaVersion = 1;

/// The conversation list's last snapshot, one JSON file in the app's private
/// support directory (path_provider's `getApplicationSupportDirectory` --
/// unlike the cache directory, the OS never clears this under storage
/// pressure).
final class FileChatListSnapshotStore implements ChatListSnapshotStore {
  FileChatListSnapshotStore({Future<Directory> Function()? root})
    : _root = root ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _root;

  /// Bumped by [clear]; a [save] in flight when it changes lost the race and
  /// must not resurrect what clear() just erased.
  int _epoch = 0;

  Future<File> _file() async => File('${(await _root()).path}/chat_list.json');

  @override
  Future<List<Conversation>?> load(String ownerId) async {
    try {
      final file = await _file();
      final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      if (raw['v'] != _schemaVersion || raw['owner'] != ownerId) {
        await clear();
        return null;
      }
      return [
        for (final e in raw['list']! as List)
          Conversation.fromJson(e as Map<String, Object?>),
      ];
    } catch (_) {
      // Missing, unreadable, wrong owner, wrong schema, corrupt JSON, or the
      // platform channel itself unavailable: all the same "nothing usable"
      // to the caller, which falls back to the network. Any leftover file is
      // removed so a bad snapshot is never retried.
      await clear();
      return null;
    }
  }

  @override
  Future<void> save(String ownerId, List<Conversation> conversations) async {
    final epoch = _epoch;
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      final body = jsonEncode({
        'v': _schemaVersion,
        'owner': ownerId,
        'list': [for (final c in conversations) c.toJson()],
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

  @override
  Future<void> clear() async {
    _epoch++;
    try {
      final file = await _file();
      if (await file.exists()) await file.delete();
      // A save's temp file too, in case a crash landed between its write and
      // rename.
      final part = File('${file.path}.part');
      if (await part.exists()) await part.delete();
    } catch (_) {
      // Nothing to clear, or nothing that can be.
    }
  }
}
