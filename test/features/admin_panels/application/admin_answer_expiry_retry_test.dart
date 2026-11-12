import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
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
  late DateTime now;

  AdminPanelsState st() => c.read(adminPanelsProvider);

  setUp(() {
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

  group('expiry', () {
    test('a sending answer older than 3 minutes becomes notSentYet', () async {
      await prepare();
      await ctrl.answerQuestion('Q-1', 'a');
      now = now.add(Duration(minutes: 2, seconds: 59));
      await ctrl.refresh();
      expect(last().status, AdminAnswerStatus.sending);
      now = now.add(Duration(seconds: 2));
      await ctrl.refresh();
      expect(last().status, AdminAnswerStatus.notSentYet);
    });

    test('a late ok:true still resolves a notSentYet answer', () async {
      await prepare();
      await ctrl.answerQuestion('Q-1', 'a');
      now = now.add(Duration(minutes: 3, seconds: 1));
      await ctrl.refresh();
      expect(last().status, AdminAnswerStatus.notSentYet);
      await deliver([okResult(last().epoch, last().upSeq)]);
      expect(last().status, AdminAnswerStatus.sent);
      expect(st().sentQuestions, contains('Q-1'));
    });

    test('a late failure resolves a notSentYet answer to notSent', () async {
      await prepare();
      await ctrl.answerQuestion('Q-1', 'a');
      now = now.add(Duration(minutes: 3, seconds: 1));
      await ctrl.refresh();
      expect(last().status, AdminAnswerStatus.notSentYet);
      await deliver([
        failResult(last().epoch, last().upSeq, AdminAnswerCode.notOpen),
      ]);
      expect(last().status, AdminAnswerStatus.notSent);
      expect(last().code, AdminAnswerCode.notOpen);
    });

    test('an answer that already got ok:true is not expired', () async {
      await prepare();
      await ctrl.answerQuestion('Q-1', 'a');
      await deliver([okResult(last().epoch, last().upSeq)]);
      now = now.add(Duration(minutes: 10));
      await ctrl.refresh();
      expect(last().status, AdminAnswerStatus.sent);
    });
  });

  group('retry', () {
    test('retry sends the same message with a new up row', () async {
      await prepare();
      await ctrl.sendTalk('hello', conv: 'c:1');
      await deliver([
        failResult(last().epoch, last().upSeq, AdminAnswerCode.notOpen),
      ]);
      final old = last();
      expect(await ctrl.retryAnswer(old), isNull);
      expect(st().answers.length, 1);
      final newAns = last();
      expect(newAns.upSeq, isNot(old.upSeq));
      expect(newAns.status, AdminAnswerStatus.sending);
      expect(newAns.message['text'], 'hello');
      expect(newAns.message['conv'], 'c:1');
      expect(repo.sent.last['text'], 'hello');
    });

    test('as a new conversation drops conv', () async {
      await prepare();
      await ctrl.sendTalk('hello', conv: 'c:1');
      await deliver([
        failResult(last().epoch, last().upSeq, AdminAnswerCode.convMissing),
      ]);
      final old = last();
      expect(await ctrl.retryAnswer(old, asNewConversation: true), isNull);
      expect(repo.sent.last.containsKey('conv'), isFalse);
      expect(repo.sent.last['text'], 'hello');
      expect(st().answers.length, 1);
      expect(last().status, AdminAnswerStatus.sending);
      expect(last().conv, isNull);
    });

    test('a retry that is later confirmed becomes sent', () async {
      await prepare();
      await ctrl.sendTalk('hello', conv: 'c:1');
      await deliver([
        failResult(last().epoch, last().upSeq, AdminAnswerCode.notOpen),
      ]);
      final old = last();
      await ctrl.retryAnswer(old);
      await deliver([okResult(last().epoch, last().upSeq)]);
      expect(last().status, AdminAnswerStatus.sent);
    });

    test('a failed retry keeps the old entry', () async {
      await prepare();
      await ctrl.sendTalk('hello', conv: 'c:1');
      await deliver([
        failResult(last().epoch, last().upSeq, AdminAnswerCode.notOpen),
      ]);
      final old = last();
      repo.sendResult = Err(NetworkFailure('x'));
      final f = await ctrl.retryAnswer(old);
      expect(f, isA<NetworkFailure>());
      expect(st().answers.length, 1);
      expect(last().upSeq, old.upSeq);
      expect(last().status, AdminAnswerStatus.notSent);
    });
  });

  group('resync window', () {
    test('resync is allowed again after 60 seconds', () async {
      await ctrl.open('reason');
      await ctrl.refresh();
      int resyncs() => repo.sent.where((m) => m['kind'] == 'resync').length;
      expect(resyncs(), 1);
      now = now.add(Duration(seconds: 59));
      await ctrl.refresh();
      expect(resyncs(), 1);
      now = now.add(Duration(seconds: 2));
      await ctrl.refresh();
      expect(resyncs(), 2);
    });
  });
}
