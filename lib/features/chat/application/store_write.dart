import 'dart:async';
import 'dart:developer';

/// Runs a fire-and-forget store write ([write] is a store call such as `store.upsertAll(rows)`). A write that still fails after the store's retries is logged by type only (never the row: it can hold message text) and not rethrown; the server stays the source of truth, so the next sync or page read rewrites the row. Use it instead of `unawaited(store.x(...))`.
void storeWrite(Future<void> write) {
  unawaited(
    write.catchError((Object e, StackTrace st) {
      log('store write failed: ${e.runtimeType}', name: 'sis.store');
    }),
  );
}
