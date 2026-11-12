import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';

import 'admin_fakes.dart';

void main() {
  late FakeAdminRepository repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late ProviderContainer c;
  late AdminPanelsController ctrl;

  AdminPanelsState st() => c.read(adminPanelsProvider);

  setUp(() {
    repo = FakeAdminRepository();
    unlock = FakeAdminUnlock();
    store = FakeAdminSnapshotStore();
    c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    ctrl = c.read(adminPanelsProvider.notifier);
  });

  Future<void> prepare() async {
    repo.fetchQueue = [
      [snapRow(1, 1, cursor: 5)],
    ];
    await ctrl.open('reason');
    await ctrl.refresh();
    expect(st().hasSnapshot, isTrue);
  }

  int nextId = 2;
  Future<void> deliver(
    List<AdminAnswerResult> r, {
    int? seq,
    int epoch = 1,
  }) async {
    final id = nextId++;
    repo.fetchQueue = [
      [deltaRow(id, seq ?? id, cursor: 5 + id, results: r, epoch: epoch)],
    ];
    await ctrl.refresh();
  }

  AdminAnswer last() => st().answers.last;

  test('send tracks a sending answer', () async {
    await prepare();
    final f = await ctrl.answerQuestion('Q-1', 'a');
    expect(f, isNull);
    expect(st().answers.length, 1);
    final a = last();
    expect(a.status, AdminAnswerStatus.sending);
    expect(a.kind, 'question');
    expect(a.targetId, 'Q-1');
  });

  test('ok:true -> sent and id in sentQuestions', () async {
    await prepare();
    await ctrl.answerQuestion('Q-1', 'a');
    await deliver([okResult(last().epoch, last().upSeq)]);
    final a = last();
    expect(a.status, AdminAnswerStatus.sent);
    expect(st().sentQuestions, contains('Q-1'));
  });

  test('ok:false -> notSent with code, id removed', () async {
    await prepare();
    await ctrl.answerQuestion('Q-1', 'a');
    await deliver([
      failResult(last().epoch, last().upSeq, AdminAnswerCode.notOpen),
    ]);
    final a = last();
    expect(a.status, AdminAnswerStatus.notSent);
    expect(a.code, AdminAnswerCode.notOpen);
    expect(st().sentQuestions, isNot(contains('Q-1')));
  });

  test('task ok -> decidedTasks contains id', () async {
    await prepare();
    await ctrl.decideTask('T-1', go: true);
    await deliver([okResult(last().epoch, last().upSeq)]);
    expect(st().decidedTasks, contains('T-1'));
  });

  test('task failure -> notSent, id removed', () async {
    await prepare();
    await ctrl.decideTask('T-1', go: true);
    await deliver([
      failResult(last().epoch, last().upSeq, AdminAnswerCode.unknownItem),
    ]);
    final a = last();
    expect(a.status, AdminAnswerStatus.notSent);
    expect(st().decidedTasks, isNot(contains('T-1')));
  });

  test('second result for same answer is ignored', () async {
    await prepare();
    await ctrl.answerQuestion('Q-1', 'a');
    await deliver([okResult(last().epoch, last().upSeq)]);
    final sentSeq = last().upSeq;
    await deliver([failResult(last().epoch, sentSeq, AdminAnswerCode.notOpen)]);
    final a = last();
    expect(a.status, AdminAnswerStatus.sent);
    expect(st().sentQuestions, contains('Q-1'));
  });

  test('result for unknown answer is ignored', () async {
    await prepare();
    await ctrl.answerQuestion('Q-1', 'a');
    await deliver([okResult(1, 999)]);
    expect(last().status, AdminAnswerStatus.sending);
    await deliver([okResult(last().epoch + 1, last().upSeq)]);
    expect(last().status, AdminAnswerStatus.sending);
  });

  test('results from a replayed row are ignored', () async {
    await prepare();
    await ctrl.answerQuestion('Q-1', 'a');
    await deliver([okResult(last().epoch, last().upSeq)], seq: 1);
    expect(last().status, AdminAnswerStatus.sending);
    await deliver([okResult(last().epoch, last().upSeq)], seq: 2);
    expect(last().status, AdminAnswerStatus.sent);
  });

  test('results from another epoch are ignored', () async {
    await prepare();
    await ctrl.answerQuestion('Q-1', 'a');
    await deliver([okResult(last().epoch, last().upSeq)], epoch: 2);
    expect(last().status, AdminAnswerStatus.sending);
  });

  test('a resync is not tracked as an answer', () async {
    await ctrl.open('reason');
    await ctrl.refresh();
    expect(repo.sent.any((m) => m['kind'] == 'resync'), isTrue);
    expect(st().answers, isEmpty);
  });

  test('two answers matched each by its own ref', () async {
    await prepare();
    await ctrl.answerQuestion('Q-1', 'a');
    await ctrl.answerQuestion('Q-2', 'b');
    final second = st().answers[1];
    await deliver([okResult(second.epoch, second.upSeq)]);
    expect(st().answers[0].status, AdminAnswerStatus.sending);
    expect(st().answers[1].status, AdminAnswerStatus.sent);
    expect(st().sentQuestions, contains('Q-2'));
  });
}
