import 'dart:developer';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/send_queue_store.dart';

/// [SendQueueStore] over shared_preferences: per member, never synced.
final class SharedPrefsSendQueueStore implements SendQueueStore {
  /// Creates the store.
  const SharedPrefsSendQueueStore();

  static const _prefix = 'sis.sendqueue.';

  @override
  Future<List<QueuedRecord>> load(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final records = decodeQueue(prefs.getString('$_prefix$userId'));
      return [
        for (final r in records)
          if (_present(r)) r,
      ];
    } catch (e) {
      log('Loading the send queue failed: ${e.runtimeType}', name: 'sis.queue');
      return const [];
    }
  }

  static bool _present(QueuedRecord r) {
    final f = r.file;
    if (f != null) return File(f.path).existsSync();
    final v = r.video;
    if (v != null) return File(v.path).existsSync();
    return r.body.isNotEmpty || r.stickerId != null || r.albumId != null;
  }

  @override
  Future<void> save(String userId, List<QueuedRecord> records) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = '$_prefix$userId';
      if (records.isEmpty) {
        await prefs.remove(key);
      } else {
        await prefs.setString(key, encodeQueue(records));
      }
    } catch (e) {
      log('Saving the send queue failed: ${e.runtimeType}', name: 'sis.queue');
    }
  }

  @override
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
      for (final key in keys) {
        await prefs.remove(key);
      }
    } catch (e) {
      log(
        'Clearing the send queue failed: ${e.runtimeType}',
        name: 'sis.queue',
      );
    }
  }
}
