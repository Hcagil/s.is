// This test is written from the contract, real SQLite3 Multiple Ciphers file,
// the interceptor is the only fake.

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/message_store.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

import 'store_harness.dart';

class _BeginFails extends QueryInterceptor {
  bool armed = false;
  int beginFailures = 0;
  int rollbacks = 0;

  final sql.SqliteException first = sql.SqliteException(
    extendedResultCode: 5,
    message: 'database is locked',
    causingStatement: 'BEGIN TRANSACTION secret-row-text',
  );

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) {
    if (armed && executor is TransactionExecutor) {
      beginFailures++;
      throw first;
    }
    return super.ensureOpen(executor, user);
  }

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) {
    if (armed) {
      rollbacks++;
      throw ArgumentError.value(
        1,
        'transactionId',
        'Does not reference a transaction',
      );
    }
    return super.rollbackTransaction(inner);
  }
}

void main() {
  group('a write whose transaction fails to start', () {
    test(
      'StoreWriteException carries the first database error, not the rollback error',
      timeout: const Timeout(Duration(seconds: 60)),
      () async {
        final h = await StoreHarness.create();
        final key = await h.newKey();
        final fault = _BeginFails();

        final store = DriftMessageStore(
          ownerId: 'owner-1',
          file: () async => h.file,
          key: () async => key,
          deleteKey: () async => h.deleteKeyCalls++,
          interceptor: fault,
        );
        addTearDown(store.close);

        // First write succeeds
        await store.upsertAll([msg('ok')]);
        expect(ids(await store.newest('c1')), [
          'ok',
        ], reason: 'fixture: the store opened and wrote for real');

        // Arm the interceptor to fail on BEGIN
        fault.armed = true;

        Object? thrown;
        try {
          await store.upsertAll([msg('fails', t: 1)]);
        } catch (e) {
          thrown = e;
        }

        expect(thrown, isA<StoreWriteException>());
        expect(
          fault.beginFailures,
          greaterThan(0),
          reason: 'fixture: the begin really failed',
        );
        expect(
          fault.rollbacks,
          greaterThan(0),
          reason: 'fixture: the masking rollback error really happened',
        );
        expect(
          (thrown! as StoreWriteException).cause,
          same(fault.first),
          reason: 'the FIRST error, not the rollback ArgumentError',
        );
        expect(
          thrown.toString(),
          'StoreWriteException',
          reason: 'no SQL text in the message',
        );
      },
    );
  });
}
