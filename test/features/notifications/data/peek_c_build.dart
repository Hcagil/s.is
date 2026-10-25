// Builds the iPhone notification extension's C store code
// (ios/NotificationService/PeekStore.c) for the host, linked with SQLite3
// Multiple Ciphers from the same pinned amalgamation and flags as
// ios/NotificationService/build_native.sh, plus a small separate-process
// lock tool on the same SQLite build. Shared by the reader and save tests.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

final _dir = Directory('.dart_tool/sis_peek_c');

Future<void> _run(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  if (r.exitCode != 0) {
    fail('$exe ${args.join(' ')}\n${r.stdout}\n${r.stderr}');
  }
}

/// The cached SQLite3 Multiple Ciphers object file.
Future<String> _sqliteObject() async {
  _dir.createSync(recursive: true);
  final obj = '${_dir.path}/sqlite3mc-$_version.o';
  if (!File(obj).existsSync()) {
    final zip = '${_dir.path}/amalgamation.zip';
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
      _dir.path,
    ]);
    await _run('clang', [
      '-c',
      '-fPIC',
      '-O1',
      '-w',
      ..._flags,
      '${_dir.path}/sqlite3mc_amalgamation.c',
      '-o',
      obj,
    ]);
  }
  return obj;
}

/// Builds PeekStore.c fresh (it may change between runs) as a shared library.
Future<String> buildPeekLib() async {
  final obj = await _sqliteObject();
  final so = '${_dir.path}/libpeek-$pid.so';
  await _run('clang', [
    '-shared',
    '-fPIC',
    '-O1',
    '-Wl,-Bsymbolic',
    '-I',
    _dir.path,
    'ios/NotificationService/PeekStore.c',
    obj,
    '-lm',
    '-lpthread',
    '-o',
    so,
  ]);
  return so;
}

// The other process (the iPhone app is a different process from its
// extension; POSIX locks never conflict inside one process, so a lock must be
// held, and a leftover lock seen, from outside).
//   lock <path> <keyhex> hold <ms> IMMEDIATE|EXCLUSIVE  prints locked/released
//   lock <path> <keyhex> write  one write with busy_timeout 0, prints written
const _lockTool = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "sqlite3.h"
int main(int argc, char **argv) {
  sqlite3 *db; char *err = 0; char q[256];
  if (argc < 4 || sqlite3_open_v2(argv[1], &db, SQLITE_OPEN_READWRITE, 0)) { puts("open_fail"); return 2; }
  snprintf(q, sizeof q, "PRAGMA key = \"x'%s'\";", argv[2]);
  if (sqlite3_exec(db, q, 0, 0, &err)) { printf("key_fail %s\n", err); return 2; }
  if (!strcmp(argv[3], "hold")) {
    snprintf(q, sizeof q, "BEGIN %s;", argv[5]);
    if (sqlite3_exec(db, q, 0, 0, &err) ||
        sqlite3_exec(db, "UPDATE meta SET value = value WHERE key = 'owner_id';", 0, 0, &err)) {
      printf("hold_fail %s\n", err); return 3;
    }
    puts("locked"); fflush(stdout);
    usleep(atoi(argv[4]) * 1000);
    if (sqlite3_exec(db, "COMMIT;", 0, 0, &err)) { printf("commit_fail %s\n", err); return 3; }
    puts("released"); fflush(stdout);
  } else {
    int rc = sqlite3_exec(db, "BEGIN IMMEDIATE; UPDATE meta SET value = value WHERE key = 'owner_id'; COMMIT;", 0, 0, &err);
    if (rc) { printf("write_fail %d %s\n", rc, err ? err : ""); return 4; }
    puts("written");
  }
  sqlite3_close(db);
  return 0;
}
''';

/// Builds the lock tool executable on the same SQLite build.
Future<String> buildLockTool() async {
  final obj = await _sqliteObject();
  final src = File('${_dir.path}/lock-$pid.c')..writeAsStringSync(_lockTool);
  final exe = '${_dir.path}/lock-$pid';
  await _run('clang', [
    '-O1',
    '-w',
    '-I',
    _dir.path,
    src.path,
    obj,
    '-lm',
    '-lpthread',
    '-o',
    exe,
  ]);
  src.deleteSync();
  return exe;
}
