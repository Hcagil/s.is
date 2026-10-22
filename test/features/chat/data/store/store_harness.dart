// Shared set-up for the on-phone store tests: a REAL SQLite3 Multiple Ciphers
// database file in a temp directory, keyed by a REAL StoreKey (over the
// flutter_secure_storage test mock). Written from the MessageStore contract,
// never from the implementation.
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/store_key.dart';
import 'package:sis/features/chat/domain/message.dart';

/// One temp directory per test; [file] is the database file in it.
class StoreHarness {
  StoreHarness._(this.dir);

  final Directory dir;
  int deleteKeyCalls = 0;

  File get file => File(p.join(dir.path, 'sis_store.sqlite'));
  File get wal => File('${file.path}-wal');
  File get shm => File('${file.path}-shm');

  static Future<StoreHarness> create() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    final h = StoreHarness._(
      await Directory.systemTemp.createTemp('sis-store-'),
    );
    addTearDown(() async {
      if (!await h.dir.exists()) return;
      try {
        await h.dir.delete(recursive: true);
      } on FileSystemException catch (e) {
        // Something still wrote here after the test closed its stores: name
        // the files, so the writer can be found (CI: "Directory not empty").
        final left = [
          if (h.dir.existsSync())
            for (final f in h.dir.listSync(recursive: true))
              p.relative(f.path, from: h.dir.path),
        ];
        fail(
          'temp folder still written after the test: '
          '${left.take(20)} ($e)',
        );
      }
    });
    return h;
  }

  /// The production key: 32 random bytes from StoreKey.
  Future<String> newKey() async {
    FlutterSecureStorage.setMockInitialValues({});
    return const StoreKey().loadOrCreate();
  }

  DriftMessageStore open({required String owner, required String key}) =>
      DriftMessageStore(
        ownerId: owner,
        file: () async => file,
        key: () async => key,
        deleteKey: () async => deleteKeyCalls++,
      );
}

/// A fixed UTC base time; message n is n minutes later (with microseconds,
/// as the server sends them).
final base = DateTime.utc(2026, 3, 1, 9, 0, 0, 0, 123);
DateTime at(int n) => base.add(Duration(minutes: n));

Message msg(
  String id, {
  String conv = 'c1',
  int t = 0,
  String body = 'hello',
  String sender = 'u1',
  MessageDeletion? deletion,
  bool sending = false,
}) => Message(
  id: id,
  conversationId: conv,
  senderId: sender,
  body: body,
  createdAt: at(t),
  deletion: deletion,
  sending: sending,
);

List<String> ids(List<Message> ms) => [for (final m in ms) m.id];
