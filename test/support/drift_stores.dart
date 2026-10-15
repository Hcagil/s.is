// The on-phone stores as lib/main.dart wires them, over a temp file: one
// REAL encrypted DriftMessageStore per signed-in user (the provider follows
// currentUserIdProvider) and the DriftChatListSnapshotStore over it.
import 'dart:io';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';

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

/// messageStoreProvider and chatListSnapshotStoreProvider as main.dart
/// overrides them. [file] replaces the file lookup (e.g. one that fails).
List<Override> driftStoreOverrides(
  Directory dir,
  String key, {
  Future<File> Function()? file,
}) => [
  messageStoreProvider.overrideWith(
    (ref) => driftStore(
      ref.watch(currentUserIdProvider) ?? '',
      dir,
      key,
      file: file,
    ),
  ),
  chatListSnapshotStoreProvider.overrideWith(
    (ref) => DriftChatListSnapshotStore(
      ref.watch(messageStoreProvider) as DriftMessageStore,
    ),
  ),
];
