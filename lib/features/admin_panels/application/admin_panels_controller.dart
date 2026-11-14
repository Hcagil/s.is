import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../domain/admin_answer.dart';
import '../domain/admin_assembler.dart';
import '../domain/admin_item.dart';
import '../domain/admin_marks.dart';
import '../domain/admin_panels_repository.dart';
import '../domain/admin_seen_store.dart';
import '../domain/admin_snapshot.dart';
import '../domain/admin_snapshot_store.dart';
import 'admin_panels_state.dart';

/// The repository for the owner-only panels (set in main).
final adminPanelsRepositoryProvider = Provider<AdminPanelsRepository>(
  (_) => throw UnimplementedError('override in main'),
);

/// The phone unlock asked before the panels open (set in main).
final adminUnlockProvider = Provider<AdminUnlock>(
  (_) => throw UnimplementedError('override in main'),
);

/// Where the last complete snapshot is kept on the phone (set in main).
final adminSnapshotStoreProvider = Provider<AdminSnapshotStore>(
  (_) => throw UnimplementedError('override in main'),
);

/// Which items the owner has seen, kept on the phone (set in main; memory only until then).
final adminSeenStoreProvider = Provider<AdminSeenStore>(
  (_) => MemoryAdminSeenStore(),
);

/// How often the panels ask the server for news (light: one small call; runs only while the app is in the foreground).
const adminPollEvery = Duration(seconds: 5);

/// The same while the link screen waits for the computer's code.
const adminLinkPollEvery = Duration(seconds: 8);

/// The clock of the panels (tests replace it).
final adminClockProvider = Provider<DateTime Function()>((_) => DateTime.now);

/// An answer with no result after this long shows as 'not sent yet'.
const adminAnswerWait = Duration(minutes: 3);

/// The panels' state; it is dropped when the screen is left.
final adminPanelsProvider =
    NotifierProvider.autoDispose<AdminPanelsController, AdminPanelsState>(
      AdminPanelsController.new,
    );

/// Unlock, link and foreground-only refresh of the owner-only panels.
class AdminPanelsController extends Notifier<AdminPanelsState> {
  Timer? _timer;
  bool _foreground = false;

  /// The panels screen is open.
  bool _screen = false;

  /// Background count mode: the owner is in the app, no unlock yet.
  bool _bg = false;
  bool _busy = false;

  /// The id of the newest down row fetched so far (this screen session).
  int _lastId = 0;

  /// The epoch of the snapshot currently loaded or being built.
  int? _epoch;

  /// The highest down sequence applied in this screen session, null before the first row.
  int? _sessionSeq;

  /// When the last full resync was asked.
  DateTime? _resyncAt;
  final _assembler = AdminAssembler();
  int _answerCounter = 0;

  /// True only while the phone unlock prompt is open.
  bool _unlocking = false;

  /// Counts lock() calls; open() gives up when it changed while it waited.
  int _lockCount = 0;

  @override
  AdminPanelsState build() {
    ref.onDispose(_stop);
    return const AdminPanelsState();
  }

  /// Asks the phone unlock, then the server; the panels open only after both.
  Future<void> open(String unlockReason) async {
    state = const AdminPanelsState();
    _unlocking = true;
    final AdminUnlockResult u;
    try {
      u = await ref.read(adminUnlockProvider).authenticate(unlockReason);
    } finally {
      _unlocking = false;
    }
    final lockedAt = _lockCount;
    if (!ref.mounted) return;

    if (u == AdminUnlockResult.cancelled) {
      state = state.copyWith(gate: AdminGate.cancelled);
      return;
    }
    if (u == AdminUnlockResult.noLock) {
      state = state.copyWith(gate: AdminGate.noLock);
      return;
    }

    final st = await ref.read(adminPanelsRepositoryProvider).status();
    if (!ref.mounted || _lockCount != lockedAt) return;
    await _apply(st);
  }

  /// Makes this phone's key and publishes it.
  Future<void> startLink() async {
    state = state.copyWith(linkBusy: true, clearFailure: true);
    final r = await ref.read(adminPanelsRepositoryProvider).startLink();
    if (!ref.mounted) return;
    switch (r) {
      case Err(:final failure):
        state = state.copyWith(linkBusy: false, failure: failure);
      case Ok(value: final s):
        await _apply(Ok(s));
    }
  }

  /// The owner tapped Matches on the code [shownCode] he saw.
  Future<void> confirmLink(String shownCode) async {
    state = state.copyWith(linkBusy: true, clearFailure: true);
    final r = await ref
        .read(adminPanelsRepositoryProvider)
        .confirmLink(shownCode);
    if (!ref.mounted) return;
    switch (r) {
      case Err(:final failure):
        state = state.copyWith(linkBusy: false, failure: failure);
      case Ok(value: final s):
        await _apply(Ok(s));
    }
  }

  /// Asks the status again (the link screen while it waits for the computer).
  Future<void> checkLink() async {
    if (state.gate != AdminGate.link || state.linkBusy) return;
    await _apply(await ref.read(adminPanelsRepositoryProvider).status());
  }

  /// True while the screen is on top and the app is in the foreground; the poll runs only then.
  void setForeground(bool on) {
    _screen = on;
    _foreground = _screen || _bg;
    if (_foreground) {
      _schedule();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// Owner in the foreground, panels closed: refresh the counts without asking the unlock.
  void startBackground() {
    if (_bg) return;
    _bg = true;
    _foreground = true;
    _schedule();
    if (state.gate == AdminGate.checking && !_unlocking) unawaited(refresh());
  }

  /// The home icon is gone (sign-out or leaving home): stop the background count; the screen's own poll, if open, goes on.
  void stopBackground() {
    _bg = false;
    _foreground = _screen;
    if (!_foreground) {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// The app went to the background: drops everything held in memory so the next open asks the unlock again. False (nothing done) only while the unlock prompt itself is open.
  bool lock() {
    if (_unlocking) return false;
    _lockCount++;
    _stop();
    _lastId = 0;
    _sessionSeq = null;
    _epoch = null;
    _resyncAt = null;
    _assembler.reset();
    state = const AdminPanelsState();
    return true;
  }

  /// Fetches what the computer sent.
  Future<void> refresh() async {
    if (_busy) return;
    _busy = true;
    final lockedAt = _lockCount;
    try {
      final repo = ref.read(adminPanelsRepositoryProvider);
      final st = await repo.status();
      if (!ref.mounted || _lockCount != lockedAt) return;
      switch (st) {
        case Err(:final failure):
          // Keep showing what is there.
          state = state.copyWith(failure: failure, conn: AdminConn.offline);
          return;
        case Ok(value: final s):
          // Background count mode never changes the gate: the screen does.
          if (state.gate == AdminGate.checking &&
              (s == null || s.phase != AdminLinkPhase.linked)) {
            return;
          }
          if (s == null || s.phase != AdminLinkPhase.linked) {
            _resetSync();
            await _apply(st);
            return;
          }
          if (_epoch != null && _epoch != s.epoch) _resetSync();
          _epoch = s.epoch;
          if (state.gate == AdminGate.checking) {
            await _loadSaved(s.epoch);
            if (!ref.mounted || _lockCount != lockedAt) return;
          }
          final fetched = await repo.fetch(_lastId);
          if (!ref.mounted || _lockCount != lockedAt) return;
          switch (fetched) {
            case Err(:final failure):
              state = state.copyWith(failure: failure, conn: AdminConn.offline);
              return;
            case Ok(value: final rows):
              state = state.copyWith(conn: AdminConn.connected);
              await _applyRows(rows, s.epoch, lockedAt);
          }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _applyRows(List<AdminRow> rows, int epoch, int lockedAt) async {
    final repo = ref.read(adminPanelsRepositoryProvider);
    final persisted = await repo.lastDownSeq(epoch);
    if (!ref.mounted || _lockCount != lockedAt) return;

    var snap = state.snapshot;
    var has = state.hasSnapshot;
    var completed = false;
    var gap = false;
    var replayed = false;
    var applied = 0;

    final results = <AdminAnswerResult>[];
    for (final row in rows) {
      if (row.id > _lastId) _lastId = row.id;
      if (row.epoch != epoch) continue;

      // A replay or a repeat is refused, row by row.
      final floor = max(persisted, _sessionSeq ?? 0);
      if (row.seq <= floor) {
        if (row.seq <= persisted) replayed = true;
        continue;
      }

      if (floor > 0 && row.seq > floor + 1) {
        gap = true;
        if (row.message == null) continue;
      }
      // After a gap no delta is applied until a fresh snapshot completes.
      if (gap && row.message is AdminDelta) continue;

      _sessionSeq = row.seq;
      applied++;

      switch (row.message) {
        case final AdminSnapshotPart part:
          results.addAll(part.results);
          final done = _assembler.addPart(part);
          if (done != null) {
            snap = done;
            has = true;
            completed = true;
            gap = false;
          }
        case final AdminDelta d:
          results.addAll(d.results);
          if (has && d.cursor > snap.cursor) {
            snap = snap.withDelta(d.items, d.cursor);
          }
        case null:
          break;
      }
    }

    if (replayed && applied == 0) {
      state = state.copyWith(failure: const DeniedFailure());
      return;
    }

    final seq = _sessionSeq;
    if (seq != null && seq > persisted) {
      await repo.saveLastDownSeq(epoch, seq);
    }
    if (!ref.mounted || _lockCount != lockedAt) return;
    if (has && rows.isNotEmpty) {
      await ref
          .read(adminSnapshotStoreProvider)
          .save(
            AdminSavedSnapshot(epoch: epoch, lastId: _lastId, snapshot: snap),
          );
    }
    if (!ref.mounted || _lockCount != lockedAt) return;

    _applyResults(results);
    _expireAnswers();

    state = state.copyWith(
      snapshot: snap,
      hasSnapshot: has,
      syncing: completed ? false : state.syncing,
      clearFailure: true,
    );

    await _ensureSeen();
    if (!ref.mounted || _lockCount != lockedAt) return;
    if (!has || gap) await _resync();
  }

  /// Applies the computer's results to the answers sent from this phone.
  void _applyResults(List<AdminAnswerResult> results) {
    if (results.isEmpty) return;
    final answers = [...state.answers];
    var questions = state.sentQuestions;
    var tasks = state.decidedTasks;
    for (final result in results) {
      final i = answers.indexWhere(
        (a) =>
            a.epoch == result.epoch &&
            a.upSeq == result.upSeq &&
            (a.status == AdminAnswerStatus.sending ||
                a.status == AdminAnswerStatus.notSentYet),
      );
      if (i < 0) continue;
      final answer = answers[i];
      final target = answer.targetId;
      if (result.ok) {
        answers[i] = answer.copyWith(status: AdminAnswerStatus.sent);
        if (target != null && answer.kind == 'question') {
          questions = {...questions, target};
        }
        if (target != null && answer.kind == 'task') {
          tasks = {...tasks, target};
        }
      } else {
        answers[i] = answer.copyWith(
          status: AdminAnswerStatus.notSent,
          code: result.code,
        );
        if (target != null) {
          questions = {...questions}..remove(target);
          tasks = {...tasks}..remove(target);
        }
      }
    }
    state = state.copyWith(
      answers: answers,
      sentQuestions: questions,
      decidedTasks: tasks,
    );
  }

  /// Marks the answers with no result after adminAnswerWait as not sent yet.
  void _expireAnswers() {
    final now = ref.read(adminClockProvider)();
    final answers = [...state.answers];
    var changed = false;
    var questions = state.sentQuestions;
    var tasks = state.decidedTasks;
    for (var i = 0; i < answers.length; i++) {
      final a = answers[i];
      if (a.status != AdminAnswerStatus.sending) continue;
      if (now.difference(a.sentAt) < adminAnswerWait) continue;
      answers[i] = a.copyWith(status: AdminAnswerStatus.notSentYet);
      changed = true;
      final target = a.targetId;
      if (target != null) {
        questions = {...questions}..remove(target);
        tasks = {...tasks}..remove(target);
      }
    }
    if (!changed) return;
    state = state.copyWith(
      answers: answers,
      sentQuestions: questions,
      decidedTasks: tasks,
    );
  }

  /// Forgets everything fetched so far (the link changed).
  void _resetSync() {
    _lastId = 0;
    _sessionSeq = null;
    _resyncAt = null;
    _assembler.reset();
    state = state.copyWith(
      snapshot: AdminSnapshot.empty,
      hasSnapshot: false,
      syncing: false,
      clearSeen: true,
    );
    unawaited(ref.read(adminSnapshotStoreProvider).clear());
    unawaited(ref.read(adminSeenStoreProvider).clear());
  }

  /// Shows the snapshot saved on the phone at once (only when it belongs to [epoch]); later rows are fetched after its last id.
  Future<void> _loadSaved(int epoch) async {
    if (state.hasSnapshot) return;
    final lockedAt = _lockCount;
    final store = ref.read(adminSnapshotStoreProvider);
    final saved = await store.load();
    if (!ref.mounted || _lockCount != lockedAt || saved == null) return;
    if (saved.epoch != epoch) {
      await store.clear();
      await ref.read(adminSeenStoreProvider).clear();
      return;
    }
    _epoch = epoch;
    _lastId = saved.lastId;
    state = state.copyWith(snapshot: saved.snapshot, hasSnapshot: true);
    await _ensureSeen();
  }

  /// Loads what was seen (first run: everything now in the snapshot counts as seen) once a snapshot is shown.
  Future<void> _ensureSeen() async {
    if (state.seen != null || !state.hasSnapshot) return;
    final lockedAt = _lockCount;
    final store = ref.read(adminSeenStoreProvider);
    final saved = await store.load();
    if (!ref.mounted || _lockCount != lockedAt || state.seen != null) return;
    final seen = saved ?? adminTabIds(state.snapshot);
    if (saved == null) unawaited(store.save(seen));
    state = state.copyWith(seen: seen);
  }

  /// Marks every item now on [tab] ('talk', 'questions' or 'tasks') as seen.
  void markSeen(String tab) {
    final seen = state.seen;
    if (seen == null) return;
    final ids = adminTabIds(state.snapshot)[tab] ?? const <String>{};
    if (ids.difference(seen[tab] ?? const <String>{}).isEmpty) return;
    final next = {...seen, tab: ids};
    state = state.copyWith(seen: next);
    unawaited(ref.read(adminSeenStoreProvider).save(next));
  }

  /// Asks the computer for a full snapshot, at most once a minute.
  Future<void> _resync() async {
    final lockedAt = _lockCount;
    final now = ref.read(adminClockProvider)();
    final at = _resyncAt;
    state = state.copyWith(syncing: true);
    if (at != null && now.difference(at) < const Duration(seconds: 60)) return;
    _resyncAt = now;
    final r = await ref.read(adminPanelsRepositoryProvider).send({
      'kind': 'resync',
    });
    if (!ref.mounted || _lockCount != lockedAt) return;
    if (r is Err<AdminSentRef?>) {
      _resyncAt = null;
      state = state.copyWith(failure: r.failure);
    }
  }

  /// A unique id for one answer (the computer applies an answer id once).
  String _newAnswerId() =>
      'a${ref.read(adminClockProvider)().microsecondsSinceEpoch}-${_answerCounter++}';

  /// Sends one up message; null = sent, else why not.
  Future<Failure?> _send(Map<String, Object?> message) async {
    final repo = ref.read(adminPanelsRepositoryProvider);
    final r = await repo.send(message);
    // A refused sequence number made the repository forget the key: show the Link screen again.
    if (r case Err(failure: DeniedFailure())) await _apply(await repo.status());
    switch (r) {
      case Err(:final failure):
        return failure;
      case Ok(value: final sent):
        if (ref.mounted) _track(message, sent);
        return null;
    }
  }

  /// Records what was just sent so the card shows as waiting.
  void _track(Map<String, Object?> message, AdminSentRef? sent) {
    final kind = message['kind'];
    final id = message['id'] as String?;
    var questions = state.sentQuestions;
    var tasks = state.decidedTasks;
    if (kind == 'question' && id != null) questions = {...questions, id};
    if (kind == 'task' && id != null) tasks = {...tasks, id};
    var answers = state.answers;
    if (sent != null) {
      answers = [
        ...answers,
        AdminAnswer(
          epoch: sent.epoch,
          upSeq: sent.upSeq,
          message: message,
          sentAt: ref.read(adminClockProvider)(),
        ),
      ];
    }
    state = state.copyWith(
      sentQuestions: questions,
      decidedTasks: tasks,
      answers: answers,
    );
  }

  /// Sends the owner's answer to one question; the card then shows as waiting.
  Future<Failure?> answerQuestion(String id, String answer) {
    return _send({
      'answer_id': _newAnswerId(),
      'kind': 'question',
      'id': id,
      'answer': answer,
    });
  }

  /// Go (true) or Discard (false) for one task; the task then leaves the list.
  Future<Failure?> decideTask(String id, {required bool go}) {
    return _send({
      'answer_id': _newAnswerId(),
      'kind': 'task',
      'id': id,
      'decision': go ? 'go' : 'discard',
    });
  }

  /// One message from the owner to the manager, into [conv] when one is open.
  Future<Failure?> sendTalk(String text, {String? conv}) => _send({
    'answer_id': _newAnswerId(),
    'kind': 'talk',
    'text': text,
    'conv': ?conv,
  });

  /// Sends an answer again with a NEW sequence number (the same answer id, so the computer applies it once). [asNewConversation] drops the conversation: the text starts a new one.
  Future<Failure?> retryAnswer(
    AdminAnswer old, {
    bool asNewConversation = false,
  }) async {
    final message = {...old.message};
    if (asNewConversation) message.remove('conv');
    final f = await _send(message);
    if (f == null && ref.mounted) {
      state = state.copyWith(
        answers: [
          for (final a in state.answers)
            if (!(a.epoch == old.epoch && a.upSeq == old.upSeq)) a,
        ],
      );
    }
    return f;
  }

  Future<void> _apply(Result<AdminStatus?> r) async {
    if (!ref.mounted) return;
    final lockedAt = _lockCount;
    switch (r) {
      case Err(:final failure):
        state = state.copyWith(
          gate: AdminGate.failed,
          failure: failure,
          linkBusy: false,
        );
      case Ok(value: null):
        state = state.copyWith(gate: AdminGate.notOwner, linkBusy: false);
      case Ok(value: final s?):
        if (s.phase == AdminLinkPhase.linked) {
          state = state.copyWith(
            gate: AdminGate.ready,
            link: s,
            linkBusy: false,
            clearFailure: true,
          );
          _schedule();
          await _loadSaved(s.epoch);
          if (!ref.mounted || _lockCount != lockedAt) return;
          await refresh();
        } else {
          _resetSync();
          state = state.copyWith(
            gate: AdminGate.link,
            link: s,
            linkBusy: false,
            clearFailure: true,
          );
          _schedule();
        }
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (!_foreground) return;
    if (state.gate != AdminGate.link &&
        state.gate != AdminGate.ready &&
        !(_bg && state.gate == AdminGate.checking)) {
      return;
    }
    _timer = Timer(
      state.gate == AdminGate.link ? adminLinkPollEvery : adminPollEvery,
      _tick,
    );
  }

  Future<void> _tick() async {
    if (!ref.mounted || !_foreground) return;
    if (state.gate == AdminGate.link) {
      await checkLink();
    } else if (state.gate == AdminGate.ready ||
        (_bg && state.gate == AdminGate.checking && !_unlocking)) {
      await refresh();
    }
    if (ref.mounted) _schedule();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _foreground = false;
    _screen = false;
    _bg = false;
  }
}
