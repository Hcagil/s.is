// MessagesController.deleteForEveryone, from the contract: the list changes at
// the call (before the repository answers) -- an own message under 15 minutes
// vanishes, an older one or someone else's (admin) becomes a placeholder
// deleted by me -- then the answer settles it: Ok cleans the on-phone store,
// Err puts the original back, and a later Realtime echo wins. The on-phone
// store is the REAL encrypted one; the server is a ChatFake that answers late.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/data/store/drift_message_store.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/notifications/application/push_controller.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';

import '../../support/fakes.dart';
import '../../support/video_fakes.dart';
import 'data/store/store_harness.dart';

const _me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(_me);
}

class _Unknown extends SessionController {
  @override
  Future<SessionState> build() async => const SignedOut();
}

/// The server answers a delete only when released, and never synchronously.
class _SlowServer extends ChatFake {
  _SlowServer() : super(self: 'u1');
  final gate = Completer<void>();

  @override
  Future<Result<void>> deleteForEveryone(Message message) async {
    await gate.future;
    return deleteForEveryoneResult ?? const Ok(null);
  }
}

Message _msg(String id, {String from = 'u1', required int minutesAgo}) =>
    Message(
      id: id,
      conversationId: 'c1',
      senderId: from,
      body: 'text $id',
      createdAt: DateTime.now().subtract(Duration(minutes: minutesAgo)),
      attachmentPath: 'c1/$id.jpg',
    );

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 300));

void main() {
  late StoreHarness h;
  late DriftMessageStore real;
  late _SlowServer chat;

  setUp(() async {
    h = await StoreHarness.create();
    real = h.open(owner: 'u1', key: await h.newKey());
    addTearDown(real.close);
    chat = _SlowServer();
  });

  Future<ProviderContainer> open(
    List<Message> history, {
    SessionController Function() session = _SignedIn.new,
  }) async {
    chat.history['c1'] = history;
    final built = ProviderContainer.test(
      overrides: [
        ...videoOverrides(),
        chatRepositoryProvider.overrideWithValue(chat),
        messageStoreProvider.overrideWithValue(real),
        presenceRepositoryProvider.overrideWithValue(PresenceFake()),
        attachmentCacheProvider.overrideWithValue(AttachmentCacheFake()),
        sessionControllerProvider.overrideWith(session),
        pushSourceProvider.overrideWithValue(PushSourceFake()),
      ],
    );
    // An unknown session never settles on a member; that is the point.
    final c = identical(session, _SignedIn.new) ? await settled(built) : built;
    c.listen(messagesProvider, (_, _) {});
    c.read(openConversationProvider.notifier).open('c1');
    await c.read(messagesProvider.future);
    await _settle();
    return c;
  }

  List<Message> shown(ProviderContainer c) =>
      c.read(messagesProvider).requireValue;
  Message row(ProviderContainer c, String id) =>
      shown(c).firstWhere((m) => m.id == id);
  Future<Result<void>> delete(ProviderContainer c, String id) =>
      c.read(messagesProvider.notifier).deleteForEveryone(row(c, id));
  Future<Set<String>> stored() async => {
    for (final m in await real.newest('c1', limit: 50)) m.id,
  };

  group('before the server answers', () {
    test('own message under 15 minutes is already vanished', () async {
      final c = await open([_msg('m1', minutesAgo: 14)]);
      final pending = delete(c, 'm1');
      await Future<void>.delayed(Duration.zero);

      final m = row(c, 'm1');
      // The body stays for the shrink-away animation; only the mark matters.
      expect(m.deletion, MessageDeletion.vanished);
      chat.gate.complete();
      await pending;
    });

    test('a vanished row keeps no attachment', () async {
      final c = await open([_msg('m1', minutesAgo: 14)]);
      final pending = delete(c, 'm1');
      await Future<void>.delayed(Duration.zero);

      expect(row(c, 'm1').deletion, MessageDeletion.vanished);
      expect(row(c, 'm1').attachmentPath, isNull);
      chat.gate.complete();
      await pending;
    });

    test(
      'own message of 15 minutes or older is already a placeholder',
      () async {
        final c = await open([_msg('m1', minutesAgo: 16)]);
        final pending = delete(c, 'm1');
        await Future<void>.delayed(Duration.zero);

        final m = row(c, 'm1');
        expect(m.deletion, MessageDeletion.placeholder);
        expect(m.deletedBy, 'u1');
        expect(m.body, isEmpty);
        chat.gate.complete();
        await pending;
      },
    );

    test(
      "someone else's message (admin) is a placeholder, even when new",
      () async {
        final c = await open([_msg('m1', from: 'u2', minutesAgo: 1)]);
        final pending = delete(c, 'm1');
        await Future<void>.delayed(Duration.zero);

        final m = row(c, 'm1');
        expect(m.deletion, MessageDeletion.placeholder);
        expect(m.deletedBy, 'u1');
        chat.gate.complete();
        await pending;
      },
    );

    test('an unknown session is not "own": placeholder', () async {
      final c = await open([_msg('m1', minutesAgo: 1)], session: _Unknown.new);
      final pending = delete(c, 'm1');
      await Future<void>.delayed(Duration.zero);

      expect(row(c, 'm1').deletion, MessageDeletion.placeholder);
      chat.gate.complete();
      await pending;
    });

    test('neighbours are untouched', () async {
      final c = await open([
        _msg('m0', minutesAgo: 20),
        _msg('m1', minutesAgo: 5),
        _msg('m2', minutesAgo: 2),
      ]);
      final pending = delete(c, 'm1');
      await Future<void>.delayed(Duration.zero);

      expect(row(c, 'm0').deletion, isNull);
      expect(row(c, 'm2').deletion, isNull);
      expect(row(c, 'm2').body, 'text m2');
      chat.gate.complete();
      await pending;
    });
  });

  group('when the server answers Ok', () {
    test('a vanished message is gone from the store', () async {
      chat.deleteForEveryoneResult = const Ok(null);
      final c = await open([
        _msg('m1', minutesAgo: 3),
        _msg('m2', minutesAgo: 2),
      ]);
      expect(await stored(), {'m1', 'm2'}, reason: 'it was stored first');
      chat.gate.complete();

      final r = await delete(c, 'm1');
      await _settle();

      expect(r, isA<Ok<void>>());
      expect(await stored(), {'m2'});
      expect(shown(c).where((m) => m.deletion == null).map((m) => m.id), [
        'm2',
      ]);
    });

    test('a placeholder message is stored as a placeholder', () async {
      chat.deleteForEveryoneResult = const Ok(null);
      final c = await open([_msg('m1', minutesAgo: 30)]);
      chat.gate.complete();

      await delete(c, 'm1');
      await _settle();

      final rows = await real.newest('c1', limit: 50);
      expect(rows.single.id, 'm1');
      expect(rows.single.deletion, MessageDeletion.placeholder);
      expect(rows.single.deletedBy, 'u1');
      expect(rows.single.body, isEmpty);
    });
  });

  group('when the server answers Err', () {
    for (final (name, from, minutes) in [
      ('vanish', 'u1', 3),
      ('placeholder', 'u1', 40),
      ('admin placeholder', 'u2', 3),
    ]) {
      test('the original is back in its place after a $name', () async {
        chat.deleteForEveryoneResult = const Err(DeniedFailure());
        final c = await open([
          _msg('m0', minutesAgo: 50),
          _msg('m1', from: from, minutesAgo: minutes),
          _msg('m2', minutesAgo: 1),
        ]);
        chat.gate.complete();

        final r = await delete(c, 'm1');
        await _settle();

        expect(r, isA<Err<void>>());
        expect((r as Err<void>).failure, isA<DeniedFailure>());
        expect(shown(c).map((m) => m.id), ['m0', 'm1', 'm2']);
        final m = row(c, 'm1');
        expect(m.deletion, isNull);
        expect(m.deletedBy, isNull);
        expect(m.body, 'text m1');
        expect(m.attachmentPath, 'c1/m1.jpg');
        expect(await stored(), {'m0', 'm1', 'm2'});
      });
    }
  });

  group('a Realtime echo after the call', () {
    Message echo(Message of, MessageDeletion d) => Message(
      id: of.id,
      conversationId: of.conversationId,
      senderId: of.senderId,
      body: '',
      createdAt: of.createdAt,
      deletion: d,
      deletedBy: of.senderId,
    );

    test(
      'a placeholder echo brings a predicted vanish back as placeholder',
      () async {
        chat.deleteForEveryoneResult = const Ok(null);
        final c = await open([_msg('m1', minutesAgo: 3)]);
        final original = row(c, 'm1');
        final pending = delete(c, 'm1');
        await Future<void>.delayed(Duration.zero);
        expect(row(c, 'm1').deletion, MessageDeletion.vanished);

        chat.deliver(echo(original, MessageDeletion.placeholder));
        await _settle();
        chat.gate.complete();
        await pending;
        await _settle();

        expect(shown(c).where((m) => m.id == 'm1'), hasLength(1));
        expect(row(c, 'm1').deletion, MessageDeletion.placeholder);
      },
    );

    test('a vanished echo replaces the row', () async {
      final c = await open([_msg('m1', from: 'u2', minutesAgo: 3)]);
      final original = row(c, 'm1');

      chat.deliver(echo(original, MessageDeletion.vanished));
      await _settle();

      expect(row(c, 'm1').deletion, MessageDeletion.vanished);
      expect(shown(c).where((m) => m.id == 'm1'), hasLength(1));
    });
  });
}
