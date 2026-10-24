// The iPhone notification extension's C store reader (ios/NotificationService/
// PeekStore.c, sis_peek_read) against a REAL encrypted store file written by
// the production Dart store and REAL Olm sessions. Written from the header and
// the contract only, never from the implementation.
//
// The reader is compiled here with clang (the development image has it) and
// linked with SQLite3 Multiple Ciphers built from the same pinned amalgamation
// and flags as ios/NotificationService/build_native.sh, then called over FFI.
@TestOn('linux')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';

import '../../chat/data/store/store_harness.dart';
import '../../crypto/data/olm_peek_store_test.dart' show Phone, ok;

// Pinned exactly as build_native.sh pins it.
const _version = '2.6.1';
const _sqlite = '3.54.0';
const _sha256 =
    '3f25af603566a23c821d8e581778b5ece2a541d2435776de57b8d845c176815a';
const _flags = [
  '-DSQLITE_THREADSAFE=1',
  '-DSQLITE_TEMP_STORE=2',
  '-DSQLITE_DQS=0',
  '-DSQLITE_OMIT_LOAD_EXTENSION',
  '-DSQLITE_DEFAULT_MEMSTATUS=0',
  '-DSQLITE_OMIT_SHARED_CACHE',
  '-DSQLITE_OMIT_DEPRECATED',
];

final class SisPeekRows extends Struct {
  external Pointer<Uint8> ownerId;
  external Pointer<Uint8> peerUserId;
  external Pointer<Uint8> storedBody;
  external Pointer<Uint8> account;
  external Pointer<Uint8> keyElsewhere;
  @Int32()
  external int sessionCount;
  external Pointer<Pointer<Uint8>> sessionIds;
  external Pointer<Pointer<Uint8>> sessionPeerIds;
  external Pointer<Pointer<Uint8>> sessionIdentityKeys;
  external Pointer<Pointer<Uint8>> sessionPickles;
}

typedef _ReadC = Int32 Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<SisPeekRows>,
);
typedef _Read = int Function(
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<SisPeekRows>,
);

final _libc = DynamicLibrary.process();
final _calloc = _libc
    .lookupFunction<
      Pointer<Void> Function(IntPtr, IntPtr),
      Pointer<Void> Function(int, int)
    >('calloc');
final _free = _libc
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'free',
    );

Pointer<Uint8> _c(String? s) {
  if (s == null) return nullptr;
  final b = utf8.encode(s);
  final p = _calloc(b.length + 1, 1).cast<Uint8>();
  p.asTypedList(b.length).setAll(0, b);
  return p;
}

String? _s(Pointer<Uint8> p) {
  if (p == nullptr) return null;
  var n = 0;
  while (p[n] != 0) {
    n++;
  }
  return utf8.decode(p.asTypedList(n));
}

/// What one sis_peek_read call returned, copied out before sis_peek_free.
class Rows {
  Rows(this.rc, SisPeekRows r)
    : ownerId = _s(r.ownerId),
      peerUserId = _s(r.peerUserId),
      storedBody = _s(r.storedBody),
      account = _s(r.account),
      keyElsewhere = _s(r.keyElsewhere),
      sessionPeers = [
        for (var i = 0; i < r.sessionCount; i++) _s(r.sessionPeerIds[i]),
      ],
      sessionKeys = [
        for (var i = 0; i < r.sessionCount; i++) _s(r.sessionIdentityKeys[i]),
      ];
  final int rc;
  final String? ownerId, peerUserId, storedBody, account, keyElsewhere;
  final List<String?> sessionPeers, sessionKeys;
}

Future<void> _run(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  if (r.exitCode != 0) {
    fail('$exe ${args.join(' ')}\n${r.stdout}\n${r.stderr}');
  }
}

/// Builds the reader fresh (the C file may change between runs) on top of a
/// cached SQLite3 Multiple Ciphers object file.
Future<String> _buildReader() async {
  final dir = Directory('.dart_tool/sis_peek_c')..createSync(recursive: true);
  final obj = '${dir.path}/sqlite3mc-$_version.o';
  if (!File(obj).existsSync()) {
    final zip = '${dir.path}/amalgamation.zip';
    await _run('curl', [
      '-fsSL',
      '--retry',
      '3',
      '-o',
      zip,
      'https://github.com/utelle/SQLite3MultipleCiphers/releases/download/'
          'v$_version/sqlite3mc-$_version-sqlite-$_sqlite-amalgamation.zip',
    ]);
    final sum = await Process.run('sha256sum', [zip]);
    expect((sum.stdout as String).split(' ').first, _sha256);
    await _run('unzip', [
      '-q',
      '-o',
      zip,
      'sqlite3mc_amalgamation.c',
      'sqlite3.h',
      '-d',
      dir.path,
    ]);
    await _run('clang', [
      '-c',
      '-fPIC',
      '-O1',
      '-w',
      ..._flags,
      '${dir.path}/sqlite3mc_amalgamation.c',
      '-o',
      obj,
    ]);
  }
  final so = '${dir.path}/libpeek-$pid.so';
  await _run('clang', [
    '-shared',
    '-fPIC',
    '-O1',
    '-Wl,-Bsymbolic',
    '-I',
    dir.path,
    'ios/NotificationService/PeekStore.c',
    obj,
    '-lm',
    '-lpthread',
    '-o',
    so,
  ]);
  return so;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late _Read read;
  late void Function(Pointer<SisPeekRows>) free;
  late Phone alice;
  late Phone bob;
  late Phone carol;

  setUpAll(() async {
    final so = await _buildReader();
    final lib = DynamicLibrary.open(so);
    read = lib.lookupFunction<_ReadC, _Read>('sis_peek_read');
    free = lib
        .lookupFunction<
          Void Function(Pointer<SisPeekRows>),
          void Function(Pointer<SisPeekRows>)
        >('sis_peek_free');
    File(so).deleteSync();
  });

  /// Bob's phone: chats c1 (with alice) and c2 (with carol); one stored Olm
  /// session with alice (alice's real identity key), none with carol; m2 is
  /// a placeholder row in c1. The store is closed afterwards.
  setUp(() async {
    alice = await Phone.make('alice');
    bob = await Phone.make('bob');
    carol = await Phone.make('carol');
    await DriftChatListSnapshotStore(bob.store).save('bob', const [
      Conversation(
        id: 'c1',
        other: Member(userId: 'alice', displayName: 'Alice'),
      ),
      Conversation(
        id: 'c2',
        other: Member(userId: 'carol', displayName: 'Carol'),
      ),
    ]);
    ok(await alice.engine.createOutbound('bob', bob.keys()));
    final m1 = ok(
      await alice.engine.encrypt(
        'bob',
        encodeEnvelope(id: 'm1', text: 'first'),
        peerIdentityKey: bob.identityKey,
      ),
    );
    ok(
      await bob.engine.decrypt(
        peerUserId: 'alice',
        peerIdentityKey: alice.identityKey,
        ciphertext: m1.ciphertext,
        olmType: m1.olmType,
      ),
    );
    await bob.store.upsertAll([
      msg('m2', conv: 'c1', sender: 'alice', body: lockedBodyPlaceholder),
    ]);
    await bob.store.close();
  });

  Rows peek({
    String conv = 'c1',
    String id = 'm2',
    String? sk,
    String? si,
    String? key,
  }) {
    final args = [
      _c(bob.h.file.path),
      _c(key ?? bob.keyHex),
      _c(conv),
      _c(id),
      _c(sk),
      _c(si),
    ];
    final out = _calloc(1, sizeOf<SisPeekRows>()).cast<SisPeekRows>();
    try {
      final rc = read(
        args[0],
        args[1],
        args[2],
        args[3],
        args[4],
        args[5],
        out,
      );
      final rows = Rows(rc, out.ref);
      free(out);
      return rows;
    } finally {
      _free(out.cast());
      for (final a in args) {
        if (a != nullptr) _free(a.cast());
      }
    }
  }

  test('the old fields are still read: owner, peer, placeholder, account and '
      "the peer's sessions with their identity keys", () {
    final r = peek();
    expect(r.rc, 0);
    expect(r.ownerId, 'bob');
    expect(r.peerUserId, 'alice');
    expect(r.storedBody, lockedBodyPlaceholder);
    expect(r.account, isNotNull);
    expect(r.sessionPeers, isNotEmpty);
    expect(r.sessionPeers, everyElement('alice'));
    expect(r.sessionKeys, everyElement(alice.identityKey));
    expect(r.keyElsewhere, isNull, reason: 'no sender key was given');
  });

  test('a wrong store key is "not readable" (1)', () {
    expect(peek(key: 'ab' * 32).rc, 1);
  });

  group('key_elsewhere', () {
    test("is set when the sender key is a stored session's key of ANOTHER "
        'user than the sender id', () {
      final r = peek(conv: 'c2', sk: alice.identityKey, si: 'carol');
      expect(r.rc, 0);
      expect(r.keyElsewhere, isNotNull);
    });

    test('is set whatever chat the push names (the check is store-wide)', () {
      // c1's own peer is alice; the claimed sender carol uses alice's key.
      expect(peek(sk: alice.identityKey, si: 'carol').keyElsewhere, isNotNull);
      // A chat that is not in the snapshot at all.
      expect(
        peek(
          conv: 'c9',
          id: 'mx',
          sk: alice.identityKey,
          si: 'carol',
        ).keyElsewhere,
        isNotNull,
      );
    });

    test('is NULL when the stored session with that key belongs to the '
        'sender itself (key matches, user is the same)', () {
      final r = peek(sk: alice.identityKey, si: 'alice');
      expect(r.rc, 0);
      expect(r.keyElsewhere, isNull);
    });

    test('is NULL when no stored session has that key (user differs, key '
        'does not match)', () {
      // carol's real key: well-formed, but no session of Bob's holds it.
      final r = peek(conv: 'c2', sk: carol.identityKey, si: 'carol');
      expect(r.rc, 0);
      expect(r.keyElsewhere, isNull);
      expect(
        peek(conv: 'c2', sk: carol.identityKey, si: 'dave').keyElsewhere,
        isNull,
      );
    });

    test('is NULL without a sender key', () {
      expect(peek(conv: 'c2', si: 'carol').keyElsewhere, isNull);
      expect(peek(conv: 'c2', sk: '', si: 'carol').keyElsewhere, isNull);
    });
  });

  group('whose sessions are read', () {
    test("a chat with a known peer reads that peer's sessions, never the "
        "sender id's", () {
      final r = peek(conv: 'c2', si: 'alice', sk: alice.identityKey);
      expect(r.rc, 0);
      expect(r.peerUserId, 'carol');
      expect(r.sessionPeers, isEmpty, reason: 'carol has no session');
      final r1 = peek(si: 'carol');
      expect(r1.peerUserId, 'alice');
      expect(r1.sessionPeers, isNotEmpty);
      expect(r1.sessionPeers, everyElement('alice'));
    });

    test('a chat with no known peer reads the sender id\'s sessions', () {
      final r = peek(conv: 'c9', id: 'mx', si: 'alice');
      expect(r.rc, 0);
      expect(r.peerUserId, isNull);
      expect(r.storedBody, isNull);
      expect(r.sessionPeers, isNotEmpty);
      expect(r.sessionPeers, everyElement('alice'));
      expect(r.sessionKeys, everyElement(alice.identityKey));
    });

    test('a chat with no known peer and no sender id reads no sessions', () {
      final r = peek(conv: 'c9', id: 'mx');
      expect(r.rc, 0);
      expect(r.peerUserId, isNull);
      expect(r.sessionPeers, isEmpty);
    });
  });

  test('the store file is byte-for-byte unchanged and no journal is left '
      'after every kind of read', () async {
    final before = await bob.h.file.readAsBytes();
    final mtime = await bob.h.file.lastModified();
    final walBefore = bob.h.wal.existsSync()
        ? await bob.h.wal.readAsBytes()
        : null;

    peek();
    peek(conv: 'c2', sk: alice.identityKey, si: 'carol');
    peek(conv: 'c9', id: 'mx', si: 'alice');
    peek(key: 'ab' * 32);

    expect(await bob.h.file.readAsBytes(), before);
    expect(await bob.h.file.lastModified(), mtime);
    expect(
      bob.h.wal.existsSync() ? await bob.h.wal.readAsBytes() : null,
      walBefore,
    );
    // The app opens it as before.
    bob.reopen();
    expect(ids(await bob.store.newest('c1')), contains('m2'));
  });
}
