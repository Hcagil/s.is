// test/features/admin_panels/application/admin_fakes.dart
import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';
import 'package:sis/features/admin_panels/domain/admin_panels_repository.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_snapshot_store.dart';

/// Fake implementation of [AdminPanelsRepository] for testing.
class FakeAdminRepository implements AdminPanelsRepository {
  /// The result returned by [status].
  Result<AdminStatus?> statusResult = const Ok(
    AdminStatus(AdminLinkPhase.linked, epoch: 1),
  );

  /// When non-null, [send] returns it. When null, [send] returns Ok(AdminSentRef(sendEpoch, nextUpSeq++)).
  Result<AdminSentRef?>? sendResult;
  int sendEpoch = 1;
  int nextUpSeq = 1;

  /// Queue of rows to return for successive [fetch] calls.
  List<List<AdminRow>> fetchQueue = [];

  /// Records the [afterId] values passed to [fetch].
  final List<int> fetchCalls = [];

  /// Records the messages passed to [send].
  final List<Map<String, Object?>> sent = [];

  /// Counts how many times [status] was called.
  int statusCalls = 0;

  /// Counts how many times [forget] was called.
  int forgetCalls = 0;

  /// Map of epoch → last down sequence.
  final Map<int, int> downSeq = {};

  @override
  Future<Result<AdminStatus?>> status() async {
    statusCalls++;
    return statusResult;
  }

  @override
  Future<Result<AdminStatus>> startLink() async {
    return const Ok(AdminStatus(AdminLinkPhase.linked, epoch: 1));
  }

  @override
  Future<Result<AdminStatus>> confirmLink(String shownCode) async {
    return const Ok(AdminStatus(AdminLinkPhase.linked, epoch: 1));
  }

  @override
  Future<Result<List<AdminRow>>> fetch(int afterId) async {
    fetchCalls.add(afterId);
    if (fetchQueue.isNotEmpty) {
      return Ok(fetchQueue.removeAt(0));
    }
    return const Ok(<AdminRow>[]);
  }

  @override
  Future<Result<AdminSentRef?>> send(Map<String, Object?> message) async {
    sent.add(message);
    return sendResult ?? Ok(AdminSentRef(sendEpoch, nextUpSeq++));
  }

  @override
  Future<int> lastDownSeq(int epoch) async {
    return downSeq[epoch] ?? 0;
  }

  @override
  Future<void> saveLastDownSeq(int epoch, int seq) async {
    downSeq[epoch] = seq;
  }

  @override
  Future<void> forget() async {
    forgetCalls++;
    statusResult = const Ok(AdminStatus(AdminLinkPhase.unlinked, epoch: 0));
  }
}

/// Fake implementation of [AdminUnlock] for testing.
class FakeAdminUnlock implements AdminUnlock {
  /// The result to return from [authenticate].
  AdminUnlockResult result = AdminUnlockResult.ok;

  /// If non-null, [authenticate] will return this future.
  Completer<AdminUnlockResult>? hold;

  /// Number of times [authenticate] was called.
  int calls = 0;

  @override
  Future<AdminUnlockResult> authenticate(String reason) async {
    calls++;
    if (hold != null) {
      return hold!.future;
    }
    return result;
  }
}

/// Fake implementation of [AdminSnapshotStore] for testing.
class FakeAdminSnapshotStore implements AdminSnapshotStore {
  /// The snapshot currently stored.
  AdminSavedSnapshot? saved;

  /// Call counters.
  int loadCalls = 0;
  int saveCalls = 0;
  int clearCalls = 0;

  @override
  Future<AdminSavedSnapshot?> load() async {
    loadCalls++;
    return saved;
  }

  @override
  Future<void> save(AdminSavedSnapshot saved) async {
    this.saved = saved;
    saveCalls++;
  }

  @override
  Future<void> clear() async {
    saved = null;
    clearCalls++;
  }
}

/// Helper to create a question [AdminItem].
AdminItem qItem(String qid, {int seq = 1, bool removed = false}) {
  return AdminItem(
    id: 'q:$qid',
    kind: 'question',
    seq: seq,
    removed: removed,
    fields: removed
        ? const {}
        : {
            'id': qid,
            'question': 'text $qid',
            'answers': ['a', 'b'],
          },
  );
}

/// Helper to create a snapshot [AdminRow].
AdminRow snapRow(
  int id,
  int seq, {
  String snapId = 's1',
  int cursor = 5,
  List<AdminItem> items = const [],
  int epoch = 1,
  List<AdminAnswerResult> results = const [],
}) {
  return AdminRow(
    id: id,
    epoch: epoch,
    seq: seq,
    message: AdminSnapshotPart(
      id: snapId,
      part: 1,
      parts: 1,
      cursor: cursor,
      truncated: false,
      items: items,
      results: results,
    ),
  );
}

/// Helper to create a delta [AdminRow].
AdminRow deltaRow(
  int id,
  int seq, {
  required int cursor,
  List<AdminItem> items = const [],
  int epoch = 1,
  List<AdminAnswerResult> results = const [],
}) {
  return AdminRow(
    id: id,
    epoch: epoch,
    seq: seq,
    message: AdminDelta(cursor: cursor, items: items, results: results),
  );
}

/// Helper to create a successful [AdminAnswerResult].
AdminAnswerResult okResult(int epoch, int upSeq) =>
    AdminAnswerResult(epoch: epoch, upSeq: upSeq, ok: true);

/// Helper to create a failed [AdminAnswerResult].
AdminAnswerResult failResult(int epoch, int upSeq, AdminAnswerCode code) =>
    AdminAnswerResult(epoch: epoch, upSeq: upSeq, ok: false, code: code);
