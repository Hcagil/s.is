import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/admin_panels/application/admin_panels_controller.dart';
import 'package:sis/features/admin_panels/application/admin_panels_state.dart';
import 'package:sis/features/admin_panels/domain/admin_item.dart';
import 'package:sis/features/admin_panels/domain/admin_answer.dart';

import 'admin_fakes.dart';

void main() {
  late FakeAdminRepository repo;
  late FakeAdminUnlock unlock;
  late FakeAdminSnapshotStore store;
  late ProviderContainer c;
  late AdminPanelsController ctrl;
  late DateTime now;

  AdminPanelsState st() => c.read(adminPanelsProvider);

  int nextId = 2;

  setUp(() {
    nextId = 2;
    repo = FakeAdminRepository();
    unlock = FakeAdminUnlock();
    store = FakeAdminSnapshotStore();
    now = DateTime.utc(2026, 1, 1, 12);
    c = ProviderContainer(
      overrides: [
        adminPanelsRepositoryProvider.overrideWithValue(repo),
        adminUnlockProvider.overrideWithValue(unlock),
        adminSnapshotStoreProvider.overrideWithValue(store),
        adminClockProvider.overrideWithValue(() => now),
      ],
    );
    addTearDown(c.dispose);
    c.listen(adminPanelsProvider, (_, _) {});
    ctrl = c.read(adminPanelsProvider.notifier);
  });

  Future<void> prepareWith(List<AdminItem> items) async {
    repo.fetchQueue = [
      [snapRow(1, 1, cursor: 5, items: items)],
    ];
    await ctrl.open('reason');
    await ctrl.refresh();
    expect(st().hasSnapshot, isTrue);
  }

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

  List<AdminItem> qs(int n) => [for (var i = 1; i <= n; i++) qItem('Q-$i')];

  AdminItem waitingQ(String id) => AdminItem(
    id: 'q:$id',
    kind: 'question',
    seq: 1,
    removed: false,
    fields: {
      'id': id,
      'question': 'text $id',
      'answers': ['a', 'b'],
      'state': 'waiting',
    },
  );

  Future<void> answerOk(String id) async {
    await ctrl.answerQuestion(id, 'a');
    await deliver([okResult(last().epoch, last().upSeq)]);
  }

  test('no questions: 0', () async {
    await prepareWith(const []);
    expect(st().unansweredQuestions, 0);
  });

  test('five questions, none answered: 5', () async {
    await prepareWith(qs(5));
    expect(st().unansweredQuestions, 5);
  });

  test('five questions, three answered ok: 2', () async {
    await prepareWith(qs(5));
    await answerOk('Q-1');
    await answerOk('Q-2');
    await answerOk('Q-3');
    expect(st().unansweredQuestions, 2);
  });

  test('an answer that is being sent already lowers the count', () async {
    await prepareWith(qs(3));
    await ctrl.answerQuestion('Q-1', 'a');
    expect(st().unansweredQuestions, 2);
  });

  test('a failed send puts the question back in the count', () async {
    await prepareWith(qs(3));
    await ctrl.answerQuestion('Q-1', 'a');
    expect(st().unansweredQuestions, 2);
    await deliver([
      failResult(last().epoch, last().upSeq, AdminAnswerCode.notOpen),
    ]);
    expect(st().unansweredQuestions, 3);
  });

  test('a question the computer reports waiting is not counted', () async {
    await prepareWith([qItem('Q-1'), waitingQ('Q-2'), qItem('Q-3')]);
    expect(st().unansweredQuestions, 2);
  });

  test(
    'a waiting question that was also answered is not counted twice',
    () async {
      await prepareWith([qItem('Q-1'), waitingQ('Q-2'), qItem('Q-3')]);
      await answerOk('Q-2');
      expect(st().unansweredQuestions, 2);
    },
  );

  test('all questions answered: 0', () async {
    await prepareWith(qs(2));
    await answerOk('Q-1');
    await answerOk('Q-2');
    expect(st().unansweredQuestions, 0);
  });

  test(
    'an answer for an id that is not a question does not lower the count',
    () async {
      await prepareWith(qs(2));
      await answerOk('Q-9');
      expect(st().unansweredQuestions, 2);
    },
  );

  test('an expired answer puts the question back in the count, a late ok drops it again', () async {
    await prepareWith(qs(2));
    await ctrl.answerQuestion('Q-1', 'a');
    expect(st().unansweredQuestions, 1);
    now = now.add(Duration(minutes: 3, seconds: 1));
    await ctrl.refresh();
    expect(st().unansweredQuestions, 2);
    await deliver([okResult(last().epoch, last().upSeq)]);
    expect(st().unansweredQuestions, 1);
  });

  test('a removed question is not counted', () async {
    await prepareWith(qs(2));
    repo.fetchQueue = [
      [
        deltaRow(2, 2, cursor: 7, items: [qItem('Q-1', seq: 2, removed: true)]),
      ],
    ];
    await ctrl.refresh();
    expect(st().unansweredQuestions, 1);
  });
}
