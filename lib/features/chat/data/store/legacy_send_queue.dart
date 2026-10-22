import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/send_queue_store.dart';

/// Moves sends the old build left in shared_preferences into [to] and removes every old queue key (a text may be in them). Only [ownerId]'s queue is moved (appended behind what [to] already holds, skipping ids it already has); any other member's old queue is just removed. Never throws.
Future<void> moveLegacySendQueue(SendQueueStore to, String ownerId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    const prefix = 'sis.sendqueue.';
    for (final key
        in prefs.getKeys().where((k) => k.startsWith(prefix)).toList()) {
      if (key == '$prefix$ownerId') {
        final old = decodeQueue(prefs.getString(key));
        if (old.isNotEmpty) {
          final held = await to.load(ownerId);
          final known = {for (final r in held) r.id};
          await to.save(ownerId, [
            ...held,
            for (final r in old)
              if (!known.contains(r.id)) r,
          ]);
        }
      }
      await prefs.remove(key);
    }
  } catch (_) {
    // Nothing to move, or preferences are unavailable.
  }
}
