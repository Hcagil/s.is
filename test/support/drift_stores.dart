// The on-phone stores as lib/main.dart wires them, over a temp file: one
// REAL encrypted DriftMessageStore per signed-in user (the provider follows
// currentUserIdProvider) and the DriftChatListSnapshotStore over it.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';

import 'store_spy.dart';

/// The database file in [dir], as the store names it in the tests.
File storeFileIn(Directory dir) => File('${dir.path}/sis_store.sqlite');

DriftMessageStore driftStore(
  String owner,
  Directory dir,
  String key, {
  Future<File> Function()? file,
}) => DriftMessageStore(
  ownerId: owner,
  file: file ?? () async => storeFileIn(dir),
  key: () async => key,
  deleteKey: () async {},
);

final _quit = Expando<bool>();

/// Ends one app run: awaits the store's close, then disposes [c]. dispose()
/// alone starts the close (ref.onDispose(store.close)) without awaiting it,
/// so a tear-down that deletes the temp folder next raced the database
/// still writing its files (CI run 39213600192: "Directory not empty").
/// A SpyStore is unwrapped to the real store. Safe to call twice, so it can
/// end a test body and also stand as its tear-down.
Future<void> quit(ProviderContainer c) async {
  if (_quit[c] ?? false) return;
  _quit[c] = true;
  final s = c.read(messageStoreProvider);
  await ((s is SpyStore ? s.inner : s) as DriftMessageStore).close();
  c.dispose();
}

/// messageStoreProvider and chatListSnapshotStoreProvider as main.dart
/// overrides them. [file] replaces the file lookup (e.g. one that fails).
List<Override> driftStoreOverrides(
  Directory dir,
  String key, {
  Future<File> Function()? file,
}) => [
  messageStoreProvider.overrideWith((ref) {
    final store = driftStore(
      ref.watch(currentUserIdProvider) ?? '',
      dir,
      key,
      file: file,
    );
    ref.onDispose(store.close);
    return store;
  }),
  chatListSnapshotStoreProvider.overrideWith(
    (ref) => DriftChatListSnapshotStore(
      ref.watch(messageStoreProvider) as DriftMessageStore,
    ),
  ),
];
