// The pending push messages are stored while the app is closed and should
// appear as a preview in the conversation list and as the first messages
// in a conversation. The tests verify that the preview is shown, unread
// counts are updated, and that lines are filtered correctly (no sender,
// locked placeholder, duplicates, or already stored rows).
import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, DebugPrintCallback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/crypto/data/push_inbox_writer.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/chat/domain/encrypted_message_repository.dart'
    show lockedBodyPlaceholder;
import 'package:sis/features/chat/domain/pending_push_messages.dart';
import 'package:sis/features/chat/application/pending_push_messages_provider.dart';

import '../../support/drift_stores.dart';
import '../../support/fakes.dart';
import '../../support/store_spy.dart' show eventually;
import '../../support/video_fakes.dart';
import 'data/store/store_harness.dart';

const _me = Member(userId: 'me', displayName: 'Maya');
const _alice = Member(userId: 'alice', displayName: 'Alice');
const _carol = Member(userId: 'carol', displayName: 'Carol');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

final _t0 = DateTime.utc(2026, 3, 1, 9);

Conversation _conv(String id, Member other, String text, {int unread = 0}) =>
    Conversation(
      id: id,
      other: other,
      lastMessage: text,
      lastMessageAt: _t0,
      lastSenderId: other.userId,
      unread: unread,
    );

/// The pending-lines source as the phone has it: a short prefs read, then the lines.
class _Pending implements PendingPushMessages {
  _Pending(this.lines);
  final List<Message> lines;
  final owners = <String>[];
  @override
  Future<List<Message>> pendingPushMessages(String ownerId) async {
    owners.add(ownerId);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return lines;
  }
}

Message _line(
  String id,
  String conv,
  String sender,
  String body,
  int minutes,
) => Message(
  id: id,
  conversationId: conv,
  senderId: sender,
  body: body,
  createdAt: _t0.add(Duration(minutes: minutes)),
);

void main() {
  late StoreHarness h;
  late String key;
  late ChatFake chat;

  setUp(() async {
    h = await StoreHarness.create();
    key = await h.newKey();
    chat = ChatFake(latency: const Duration(milliseconds: 2));
    // The previous run: the list and one stored message are on the phone.
    final s = driftStore('me', h.dir, key);
    await DriftChatListSnapshotStore(s).save('me', [
      _conv('c1', _alice, 'old'),
      _conv('c2', _carol, 'carol old'),
    ]);
    await s.upsertAll([
      Message(
        id: 'm1',
        conversationId: 'c1',
        senderId: 'alice',
        body: 'old',
        createdAt: _t0,
      ),
    ]);
    await s.close();
  });

  /// The notification saves [id] with the app closed (or not reading).
  void push(String id, String body, {String conv = 'c1', int minutes = 1}) {
    final code = writePushInbox(
      path: storeFileIn(h.dir).path,
      keyHex: key,
      conversationId: conv,
      messageId: id,
      peerUserId: conv == 'c1' ? 'alice' : 'carol',
      body: body,
      sealed: 'ab' * 32,
      receivedAtMicros: _t0
          .add(Duration(minutes: minutes))
          .microsecondsSinceEpoch,
      budgetMs: 3000,
    );
    expect(code, 'saved', reason: 'fixture: the push writer saved it');
  }

  /// The app after the session settled, as SessionGate mounts it.
  Future<ProviderContainer> app(_Pending pending) async {
    final c = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        sessionControllerProvider.overrideWith(_SignedIn.new),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
        pendingPushMessagesProvider.overrideWithValue(pending),
        ...driftStoreOverrides(h.dir, key),
      ],
    );
    addTearDown(() => quit(c));
    c.listen(currentUserIdProvider, (_, _) {});
    await c.read(sessionControllerProvider.future);
    return c;
  }

  Conversation byId(List<Conversation> l, String id) =>
      l.firstWhere((x) => x.id == id);

  Future<T> logged<T>(List<String> log, Future<T> Function() body) async {
    final DebugPrintCallback old = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) {
      if (m != null) log.add(m);
    };
    try {
      return await runZoned(
        body,
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => log.add(line),
        ),
      );
    } finally {
      debugPrint = old;
    }
  }

  Future<List<Conversation>> firstList(ProviderContainer c) async {
    chat.holdList();
    final seen = <AsyncValue<List<Conversation>>>[];
    c.listen(
      conversationListProvider,
      (_, next) => seen.add(next),
      fireImmediately: true,
    );
    await eventually(
      () => seen.any((s) => s is AsyncData),
      reason: 'the first list while the server never answers',
    );
    return seen.firstWhere((s) => s is AsyncData).value!;
  }

  Future<List<String>> firstPaint(ProviderContainer c, String conv) async {
    chat.holdMessages();
    final seen = <AsyncValue<List<Message>>>[];
    c.listen(
      messagesProvider,
      (_, next) => seen.add(next),
      fireImmediately: true,
    );
    c.read(openConversationProvider.notifier).open(conv);
    await eventually(
      () => seen.any((s) => s is AsyncData && s.value!.isNotEmpty),
      reason: 'the first paint before the server answers',
    );
    final first = seen
        .firstWhere((s) => s is AsyncData && s.value!.isNotEmpty)
        .value!;
    return [for (final m in first) m.id];
  }

  Future<void> seedReadRow() async {
    final s = driftStore('me', h.dir, key);
    await s.upsertAll([
      Message(
        id: 'p1',
        conversationId: 'c1',
        senderId: 'alice',
        body: 'new',
        createdAt: _t0.add(const Duration(minutes: 1)),
      ),
    ]);
    await DriftChatListSnapshotStore(s).save('me', [
      _conv('c1', _alice, 'new'),
      _conv('c2', _carol, 'carol old'),
    ]);
    await s.close();
  }

  group('chat list, first AsyncData, server never answers', () {
    test('a pending line is the preview and +1 unread in the first list; list-push-rows is marked', () async {
      final p = _Pending([_line('p1', 'c1', 'alice', 'new', 1)]);
      final log = <String>[];
      final c = await app(p);
      final l = await logged(log, () => firstList(c));
      final c1 = byId(l, 'c1');
      expect(c1.lastMessage, 'new');
      expect(c1.unread, 1);
      expect(c1.lastSenderId, 'alice');
      final c2 = byId(l, 'c2');
      expect(c2.lastMessage, 'carol old');
      expect(c2.unread, 0);
      expect(l.first.id, 'c1', reason: 'newest chat on top');
      expect(log.any((x) => x.contains('list-push-rows')), isTrue);
      expect(p.owners, contains('me'));
      chat.releaseList();
    });

    test('a line without a sender id is skipped', () async {
      final p = _Pending([
        _line('p0', 'c1', '', 'no sender', 1),
        _line('p2', 'c2', 'carol', 'carol new', 2),
      ]);
      final c = await app(p);
      final l = await firstList(c);
      final c1 = byId(l, 'c1');
      expect(c1.lastMessage, 'old');
      expect(c1.unread, 0);
      final c2 = byId(l, 'c2');
      expect(c2.lastMessage, 'carol new');
      expect(c2.unread, 1);
      chat.releaseList();
    });

    test(
      'a placeholder line from a preview-none push (no "u") is skipped',
      () async {
        final p = _Pending([
          _line('p0', 'c1', '', 'Yeni mesaj', 1),
          _line('p2', 'c2', 'carol', 'carol new', 2),
        ]);
        final c = await app(p);
        final l = await firstList(c);
        final c1 = byId(l, 'c1');
        expect(c1.lastMessage, 'old');
        expect(c1.unread, 0);
        final c2 = byId(l, 'c2');
        expect(c2.lastMessage, 'carol new');
        expect(c2.unread, 1);
        chat.releaseList();
      },
    );

    test('a locked placeholder line is skipped', () async {
      final p = _Pending([
        _line('p0', 'c1', 'alice', lockedBodyPlaceholder, 1),
        _line('p2', 'c2', 'carol', 'carol new', 2),
      ]);
      final c = await app(p);
      final l = await firstList(c);
      final c1 = byId(l, 'c1');
      expect(c1.lastMessage, 'old');
      expect(c1.unread, 0);
      final c2 = byId(l, 'c2');
      expect(c2.lastMessage, 'carol new');
      expect(c2.unread, 1);
      chat.releaseList();
    });

    test('a line already saved as a push row counts once', () async {
      push('p1', 'new', minutes: 1);
      final p = _Pending([_line('p1', 'c1', 'alice', 'new', 1)]);
      final c = await app(p);
      final l = await firstList(c);
      final c1 = byId(l, 'c1');
      expect(c1.lastMessage, 'new');
      expect(c1.unread, 1);
      chat.releaseList();
    });

    test('a line whose real row is already stored counts nothing', () async {
      await seedReadRow();
      final p = _Pending([_line('p1', 'c1', 'alice', 'new', 1)]);
      final c = await app(p);
      final l = await firstList(c);
      final c1 = byId(l, 'c1');
      expect(c1.lastMessage, 'new');
      expect(c1.unread, 0);
      chat.releaseList();
    });
  });

  group('chat, first messages, server never answers', () {
    test('the pending line follows the stored rows', () async {
      final p = _Pending([_line('p1', 'c1', 'alice', 'new', 1)]);
      final c = await app(p);
      final ids = await firstPaint(c, 'c1');
      expect(ids, ['m1', 'p1']);
      final p1 = c
          .read(messagesProvider)
          .value!
          .firstWhere((m) => m.id == 'p1');
      expect(p1.body, 'new');
      expect(p1.senderId, 'alice');
      chat.releaseMessages();
    });

    test(
      'lines without a sender id or with the locked placeholder are not shown',
      () async {
        final p = _Pending([
          _line('p0', 'c1', '', 'no sender', 1),
          _line('p3', 'c1', 'alice', lockedBodyPlaceholder, 2),
          _line('p1', 'c1', 'alice', 'new', 3),
        ]);
        final c = await app(p);
        final ids = await firstPaint(c, 'c1');
        expect(ids, ['m1', 'p1']);
        chat.releaseMessages();
      },
    );

    test('a line already saved as a push row is shown once', () async {
      push('p1', 'new', minutes: 1);
      final p = _Pending([_line('p1', 'c1', 'alice', 'new', 1)]);
      final c = await app(p);
      final ids = await firstPaint(c, 'c1');
      expect(ids, ['m1', 'p1']);
      chat.releaseMessages();
    });

    test('a line whose real row is stored is shown once', () async {
      await seedReadRow();
      final p = _Pending([_line('p1', 'c1', 'alice', 'new', 1)]);
      final c = await app(p);
      final ids = await firstPaint(c, 'c1');
      expect(ids, ['m1', 'p1']);
      chat.releaseMessages();
    });
  });
}
