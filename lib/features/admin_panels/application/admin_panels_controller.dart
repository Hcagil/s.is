import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../domain/admin_assembler.dart';
import '../domain/admin_item.dart';
import '../domain/admin_panels_repository.dart';
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

/// How often the open panels ask the server for news (light: one small call; stops when the screen is left or the app goes to the background).
const adminPollEvery = Duration(seconds: 20);

/// The same while the link screen waits for the computer's code.
const adminLinkPollEvery = Duration(seconds: 8);

/// The panels' state; it is dropped when the screen is left.
final adminPanelsProvider =
    NotifierProvider.autoDispose<AdminPanelsController, AdminPanelsState>(
      AdminPanelsController.new,
    );

/// Unlock, link and foreground-only refresh of the owner-only panels.
class AdminPanelsController extends Notifier<AdminPanelsState> {
  Timer? _timer;
  bool _foreground = false;
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

  @override
  AdminPanelsState build() {
    ref.onDispose(_stop);
    return const AdminPanelsState();
  }

  /// Asks the phone unlock, then the server; the panels open only after both.
  Future<void> open(String unlockReason) async {
    state = const AdminPanelsState();
    final u = await ref.read(adminUnlockProvider).authenticate(unlockReason);
    if (!ref.mounted) return;

    if (u == AdminUnlockResult.cancelled) {
      state = state.copyWith(gate: AdminGate.cancelled);
      return;
    }
    if (u == AdminUnlockResult.noLock) {
      state = state.copyWith(gate: AdminGate.noLock);
      return;
    }

    await _apply(await ref.read(adminPanelsRepositoryProvider).status());
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

  /// The owner tapped Matches.
  Future<void> confirmLink() async {
    state = state.copyWith(linkBusy: true, clearFailure: true);
    final r = await ref.read(adminPanelsRepositoryProvider).confirmLink();
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
    _foreground = on;
    if (on) {
      _schedule();
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  /// The app went to the background: drops everything held in memory so the next open asks the unlock again. False (nothing done) while the unlock itself is running.
  bool lock() {
    if (state.gate == AdminGate.checking) return false;
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
    try {
      final repo = ref.read(adminPanelsRepositoryProvider);
      final st = await repo.status();
      if (!ref.mounted) return;
      switch (st) {
        case Err(:final failure):
          // Keep showing what is there.
          state = state.copyWith(failure: failure);
          return;
        case Ok(value: final s):
          if (s == null || s.phase != AdminLinkPhase.linked) {
            _resetSync();
            await _apply(st);
            return;
          }
          if (_epoch != null && _epoch != s.epoch) _resetSync();
          _epoch = s.epoch;
          final fetched = await repo.fetch(_lastId);
          if (!ref.mounted) return;
          switch (fetched) {
            case Err(:final failure):
              state = state.copyWith(failure: failure);
              return;
            case Ok(value: final rows):
              await _applyRows(rows, s.epoch);
          }
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _applyRows(List<AdminRow> rows, int epoch) async {
    final repo = ref.read(adminPanelsRepositoryProvider);
    final persisted = await repo.lastDownSeq(epoch);

    // Older rows than this phone already saw: the server replayed; apply nothing.
    if (rows.isNotEmpty && rows.last.seq < persisted) {
      state = state.copyWith(failure: const DeniedFailure());
      return;
    }

    var snap = state.snapshot;
    var has = state.hasSnapshot;
    var completed = false;
    var gap = false;

    for (final row in rows) {
      if (row.id > _lastId) _lastId = row.id;
      if (row.epoch != epoch) continue;

      final last = _sessionSeq;
      // A replay or a repeat is refused.
      if (last != null && row.seq <= last) continue;

      if (last != null && row.seq > last + 1) {
        gap = true;
      } else if (last == null && persisted > 0 && row.seq > persisted + 1) {
        gap = true;
      }

      _sessionSeq = row.seq;

      switch (row.message) {
        case final AdminSnapshotPart part:
          final done = _assembler.addPart(part);
          if (done != null) {
            snap = done;
            has = true;
            completed = true;
            gap = false;
          }
        case final AdminDelta d:
          if (has && d.cursor > snap.cursor) {
            snap = snap.withDelta(d.items, d.cursor);
          }
        case null:
          break;
      }
    }

    final seq = _sessionSeq;
    if (seq != null) await repo.saveLastDownSeq(epoch, seq);
    if (has && rows.isNotEmpty) {
      await ref
          .read(adminSnapshotStoreProvider)
          .save(
            AdminSavedSnapshot(epoch: epoch, lastId: _lastId, snapshot: snap),
          );
    }
    if (!ref.mounted) return;

    state = state.copyWith(
      snapshot: snap,
      hasSnapshot: has,
      syncing: completed ? false : state.syncing,
      clearFailure: true,
    );

    if (!has || gap) await _resync();
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
    );
    unawaited(ref.read(adminSnapshotStoreProvider).clear());
  }

  /// Shows the snapshot saved on the phone at once (only when it belongs to [epoch]); later rows are fetched after its last id.
  Future<void> _loadSaved(int epoch) async {
    if (state.hasSnapshot) return;
    final store = ref.read(adminSnapshotStoreProvider);
    final saved = await store.load();
    if (!ref.mounted || saved == null) return;
    if (saved.epoch != epoch) {
      await store.clear();
      return;
    }
    _epoch = epoch;
    _lastId = saved.lastId;
    state = state.copyWith(snapshot: saved.snapshot, hasSnapshot: true);
  }

  /// Asks the computer for a full snapshot, at most once a minute.
  Future<void> _resync() async {
    final now = DateTime.now();
    final at = _resyncAt;
    state = state.copyWith(syncing: true);
    if (at != null && now.difference(at) < const Duration(seconds: 60)) return;
    _resyncAt = now;
    final r = await ref.read(adminPanelsRepositoryProvider).send({
      'kind': 'resync',
    });
    if (!ref.mounted) return;
    if (r is Err<void>) {
      _resyncAt = null;
      state = state.copyWith(failure: r.failure);
    }
  }

  /// A unique id for one answer (the computer applies an answer id once).
  String _newAnswerId() =>
      'a${DateTime.now().microsecondsSinceEpoch}-${_answerCounter++}';

  /// Sends one up message; null = sent, else why not.
  Future<Failure?> _send(Map<String, Object?> message) async {
    final repo = ref.read(adminPanelsRepositoryProvider);
    final r = await repo.send(message);
    // A refused sequence number made the repository forget the key: show the Link screen again.
    if (r case Err(failure: DeniedFailure())) await _apply(await repo.status());
    return switch (r) {
      Err(:final failure) => failure,
      Ok() => null,
    };
  }

  /// Sends the owner's answer to one question; the card then shows as waiting.
  Future<Failure?> answerQuestion(String id, String answer) async {
    final f = await _send({
      'answer_id': _newAnswerId(),
      'kind': 'question',
      'id': id,
      'answer': answer,
    });
    if (f == null && ref.mounted) {
      state = state.copyWith(sentQuestions: {...state.sentQuestions, id});
    }
    return f;
  }

  /// Go (true) or Discard (false) for one task; the task then leaves the list.
  Future<Failure?> decideTask(String id, {required bool go}) async {
    final f = await _send({
      'answer_id': _newAnswerId(),
      'kind': 'task',
      'id': id,
      'decision': go ? 'go' : 'discard',
    });
    if (f == null && ref.mounted) {
      state = state.copyWith(decidedTasks: {...state.decidedTasks, id});
    }
    return f;
  }

  /// One message from the owner to the manager.
  Future<Failure?> sendTalk(String text) =>
      _send({'answer_id': _newAnswerId(), 'kind': 'talk', 'text': text});

  Future<void> _apply(Result<AdminStatus?> r) async {
    if (!ref.mounted) return;
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
    if (state.gate != AdminGate.link && state.gate != AdminGate.ready) return;
    _timer = Timer(
      state.gate == AdminGate.link ? adminLinkPollEvery : adminPollEvery,
      _tick,
    );
  }

  Future<void> _tick() async {
    if (!ref.mounted || !_foreground) return;
    if (state.gate == AdminGate.link) {
      await checkLink();
    } else if (state.gate == AdminGate.ready) {
      await refresh();
    }
    if (ref.mounted) _schedule();
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _foreground = false;
  }
}
