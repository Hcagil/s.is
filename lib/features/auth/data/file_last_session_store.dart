import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../domain/last_session.dart';

const _schemaVersion = 1;

/// The last confirmed session marker, one JSON file in the app's private
/// support directory beside chat_list.json.
final class FileLastSessionStore implements LastSessionStore {
  FileLastSessionStore({Future<Directory> Function()? root})
    : _root = root ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _root;

  /// Bumped by [clear]; a [save] in flight when it changes lost the race and
  /// must not resurrect what clear() just erased.
  int _epoch = 0;

  Future<File> _file() async =>
      File('${(await _root()).path}/last_session.json');

  @override
  Future<LastSession?> load() async {
    try {
      final file = await _file();
      if (!(await file.exists())) return null;
      final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
      if (raw['v'] != _schemaVersion) {
        await clear();
        return null;
      }
      return LastSession.fromJson(raw['session'] as Map<String, Object?>);
    } catch (_) {
      // Unreadable, wrong schema, corrupt JSON, or the platform channel itself
      // unavailable: all the same "nothing usable" to the caller, which takes
      // the gated path. A leftover file is removed so it is never retried.
      await clear();
      return null;
    }
  }

  @override
  Future<void> save(LastSession session) async {
    final epoch = _epoch;
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      final body = jsonEncode({
        'v': _schemaVersion,
        'session': session.toJson(),
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
      // Best-effort: the next cold start just takes the gated path. No
      // half-written temp file is left behind.
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
    final File file;
    try {
      file = await _file();
    } catch (_) {
      return; // Root itself is unavailable; nothing to clear.
    }
    final part = File('${file.path}.part');
    // Each delete is caught on its own: a save's rename can land between any
    // two of these, and the trailing delete of `file` catches that.
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
