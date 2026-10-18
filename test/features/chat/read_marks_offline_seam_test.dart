// The seam ReadMarksController <-> phone store, wired as lib/main.dart wires
// it: a REAL encrypted DriftMessageStore per signed-in user and
// readMarkStoreProvider = DriftReadMarkStore over it. Only the server is a
// fake (ChatFake), so it can be offline. The owner's bug: with the internet
// off, old messages showed but the seen tick and the readers card vanished.
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/data/store/drift_read_mark_store.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';

import '../../support/drift_stores.dart';
import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const key = '0123456789abcdef0123456789abcdef';

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

final t0 = DateTime.utc(2026, 9, 25, 10);
final t1 = t0.add(const Duration(minutes: 1));
final t2 = t0.add(const Duration(minutes: 2));
final sentBefore = t0.subtract(const Duration(minutes: 1));

List<(String, bool, DateTime?)> rows(List<ReadMark>? marks) => [
  for (final m in marks ?? const <ReadMark>[]) (m.userId, m.shares, m.readAt),
]..sort((a, b) => a.$1.compareTo(b.$1));

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sis-read-marks-');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
  });

  /// One app run over the same phone file.
  Future<ProviderContainer> app(ChatFake chat) async {
    final c = ProviderContainer.test(
      overrides: [
        chatRepositoryProvider.overrideWithValue(chat),
        profileRepositoryProvider.overrideWithValue(
          ProfileFake(
            profile: const OwnProfile(
              userId: 'u1',
              displayName: 'Maya',
              tag: 'maya',
              onboardingDone: true,
              shareReadStatus: true,
            ),
          ),
        ),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        ...driftStoreOverrides(dir, key),
        // As main.dart.
        readMarkStoreProvider.overrideWith((ref) {
          return DriftReadMarkStore(
            ref.watch(messageStoreProvider) as DriftMessageStore,
          );
        }),
      ],
    );
    await settled(c);
    c.listen(ownProfileProvider, (_, _) {});
    await c.read(ownProfileProvider.future);
    await c.read(sessionControllerProvider.future);
    c.read(openConversationProvider.notifier).open('c1');
    c.listen(readMarksProvider, (_, _) {}, fireImmediately: true);
    return c;
  }

  Future<void> until(bool Function() ok, String why) async {
    final sw = Stopwatch()..start();
    while (!ok()) {
      if (sw.elapsed > const Duration(seconds: 5)) fail(why);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  List<(String, bool, DateTime?)> shown(ProviderContainer c) =>
      rows(c.read(readMarksProvider).value);

  Future<void> onlineRun(List<ReadMark> server) async {
    final chat = ChatFake()..readMarksData['c1'] = server;
    final c = await app(chat);
    await until(() => shown(c).length == server.length, 'online load');
    // The save is behind the answer; give the real file a moment.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    c.dispose();
  }

  test(
    'online once, then offline: seen tick and readers card still show',
    () async {
      await onlineRun([
        ReadMark(userId: 'u2', shares: true, readAt: t0),
        ReadMark(userId: 'u3', shares: true, readAt: t1),
      ]);

      final chat = ChatFake()
        ..readMarksResult = const Err(NetworkFailure('offline'));
      final c = await app(chat);
      await until(() => shown(c).isNotEmpty, 'nothing shown offline');
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(c.read(readMarksProvider).hasError, isFalse);
      final marks = c.read(readMarksProvider).requireValue;
      expect(rows(marks), [('u2', true, t0), ('u3', true, t1)]);
      expect(
        marks.firstWhere((m) => m.userId == 'u2').hasRead(sentBefore),
        isTrue,
        reason: '1:1 seen tick gone offline',
      );
      expect(readersOf(marks, sentBefore).map((m) => m.userId), [
        'u2',
        'u3',
      ], reason: 'group readers card empty offline');
      c.dispose();
    },
  );

  test('stored marks show while the server is slow; its answer updates the '
      'screen and the file', () async {
    await onlineRun([ReadMark(userId: 'u2', shares: true, readAt: t0)]);

    final chat = ChatFake()
      ..readMarksData['c1'] = [ReadMark(userId: 'u2', shares: true, readAt: t2)]
      ..holdReadMarks();
    final c = await app(chat);
    await until(() => shown(c).isNotEmpty, 'stored marks waited for server');
    expect(shown(c), [('u2', true, t0)]);

    chat.releaseReadMarks();
    await until(() => shown(c).firstOrNull?.$3 == t2, 'no refresh');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    c.dispose();

    final offline = await app(
      ChatFake()..readMarksResult = const Err(NetworkFailure('offline')),
    );
    await until(() => shown(offline).isNotEmpty, 'nothing stored');
    expect(shown(offline), [('u2', true, t2)], reason: 'refresh not saved');
    offline.dispose();
  });

  test('a member who stopped sharing has no read time offline', () async {
    await onlineRun([ReadMark(userId: 'u2', shares: true, readAt: t0)]);
    await onlineRun(const [ReadMark(userId: 'u2', shares: false)]);

    final c = await app(
      ChatFake()..readMarksResult = const Err(NetworkFailure('offline')),
    );
    await until(() => shown(c).isNotEmpty, 'nothing stored');
    expect(shown(c), [('u2', false, null)]);
    c.dispose();
  });
}
