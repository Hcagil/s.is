// PhoneBookController and MessagesController.sendContact against the
// FakePhoneBook / FakeContactShare (test/support/contact_fakes.dart), written
// from the contract: access is asked only when the list opens; denied,
// permanently denied and ready states; a pending bubble replaced on success,
// removed on failure; DeniedFailure when the chat or contact is not sendable.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/phone_book.dart';
import 'package:sis/features/chat/domain/shared_contact.dart';

import '../../support/contact_fakes.dart';
import '../../support/fakes.dart';
import '../../support/poll_fakes.dart';
import '../../support/reaction_fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<void> until(bool Function() ok) async {
  for (var i = 0; i < 400; i++) {
    if (ok()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('condition never held');
}

Future<ProviderContainer> make({
  FakePhoneBook? book,
  FakeContactShare? share,
}) => settled(
  ProviderContainer.test(
    overrides: [
      chatRepositoryProvider.overrideWithValue(ChatFake()),
      pollRepositoryProvider.overrideWithValue(PollFake()),
      reactionRepositoryProvider.overrideWithValue(ReactionFake()),
      phoneBookProvider.overrideWithValue(book ?? FakePhoneBook()),
      contactShareRepositoryProvider.overrideWithValue(
        share ?? FakeContactShare(),
      ),
      sessionControllerProvider.overrideWith(_SignedIn.new),
    ],
  ),
);

void main() {
  group('PhoneBookController', () {
    test('does not ask for permission until controller is read', () async {
      final book = FakePhoneBook();
      final c = await make(book: book);
      // Reading unrelated providers should not trigger permission request
      c.read(messagesProvider);
      c.read(phoneBookProvider);
      expect(book.accessCalls, 0);
      // Opening the list (listening to the controller) asks.
      c.listen(phoneBookControllerProvider, (_, _) {});
      await c.read(phoneBookControllerProvider.future);
      expect(book.accessCalls, 1);
    });

    test('granted access returns ready state with entries', () async {
      final book = FakePhoneBook(
        contacts: [
          PhoneBookEntry(id: 'e1', name: 'Alice', phone: '+123'),
          PhoneBookEntry(id: 'e2', name: 'Bob', phone: '+456'),
        ],
      );
      final c = await make(book: book);
      c.listen(phoneBookControllerProvider, (_, _) {});
      final state = await c.read(phoneBookControllerProvider.future);
      expect(state, isA<PhoneBookReady>());
      final ready = state as PhoneBookReady;
      expect(ready.entries.map((e) => e.id).toList(), ['e1', 'e2']);
      expect(book.accessCalls, 1);
    });

    test('prompt open shows loading and no entries until granted', () async {
      final book = FakePhoneBook();
      book.prompt = Completer<void>();
      final c = await make(book: book);
      c.listen(phoneBookControllerProvider, (_, _) {});
      final asyncValue = c.read(phoneBookControllerProvider);
      expect(asyncValue.isLoading, true);
      expect(book.entriesCalls, 0);
      // Complete the prompt to grant access
      book.prompt!.complete();
      await until(() => c.read(phoneBookControllerProvider).hasValue);
      final state = c.read(phoneBookControllerProvider).value;
      expect(state, isA<PhoneBookReady>());
      expect(book.entriesCalls, greaterThan(0));
    });

    test('denied access returns denied state (non‑permanent)', () async {
      final book = FakePhoneBook(access: PhoneBookAccess.denied);
      final c = await make(book: book);
      c.listen(phoneBookControllerProvider, (_, _) {});
      final state = await c.read(phoneBookControllerProvider.future);
      expect(state, isA<PhoneBookDenied>());
      final denied = state as PhoneBookDenied;
      expect(denied.permanent, false);
    });

    test(
      'permanently denied access returns denied state (permanent)',
      () async {
        final book = FakePhoneBook(access: PhoneBookAccess.permanentlyDenied);
        final c = await make(book: book);
        c.listen(phoneBookControllerProvider, (_, _) {});
        final state = await c.read(phoneBookControllerProvider.future);
        expect(state, isA<PhoneBookDenied>());
        final denied = state as PhoneBookDenied;
        expect(denied.permanent, true);
      },
    );

    test('retryAccess after denied succeeds when permission granted', () async {
      final book = FakePhoneBook(access: PhoneBookAccess.denied);
      final c = await make(book: book);
      c.listen(phoneBookControllerProvider, (_, _) {});
      await c.read(phoneBookControllerProvider.future); // denied
      book.access = PhoneBookAccess.granted;
      await c.read(phoneBookControllerProvider.notifier).retryAccess();
      await until(
        () => c.read(phoneBookControllerProvider).value is PhoneBookReady,
      );
      expect(book.accessCalls, 2);
    });

    test('retryAccess while still denied keeps denied state', () async {
      final book = FakePhoneBook(access: PhoneBookAccess.denied);
      final c = await make(book: book);
      c.listen(phoneBookControllerProvider, (_, _) {});
      await c.read(phoneBookControllerProvider.future); // denied
      await c.read(phoneBookControllerProvider.notifier).retryAccess();
      final state = c.read(phoneBookControllerProvider).value;
      expect(state, isA<PhoneBookDenied>());
      final denied = state as PhoneBookDenied;
      expect(denied.permanent, false);
    });
  });

  group('sendContact', () {
    late FakeContactShare share;
    Future<ProviderContainer> setup() async {
      share = FakeContactShare()..gate = Completer<void>();
      final c = await make(share: share);
      c.listen(messagesProvider, (_, _) {});
      c.read(openConversationProvider.notifier).open('c1');
      await until(() => c.read(messagesProvider).hasValue);
      return c;
    }

    test('pending then stored on success', () async {
      final c = await setup();
      final f = c
          .read(messagesProvider.notifier)
          .sendContact(const SharedContact(name: 'Ann Lee', phone: '+90 555'));
      await until(() => share.calls.isNotEmpty);
      final call = share.calls.single;
      expect(call.$1, 'c1');
      expect(call.$3.name, 'Ann Lee');
      expect(call.$3.phone, '+90 555');
      final id = call.$2;
      final msgs = c.read(messagesProvider).requireValue;
      final pending = msgs.firstWhere((m) => m.id == id);
      expect(pending.contact, true);
      expect(pending.sending, true);
      expect(pending.body, 'Ann Lee\n+90 555');
      // Complete the send
      share.gate!.complete();
      final result = await f;
      expect(result, isA<Ok<void>>());
      final finalMsgs = c.read(messagesProvider).requireValue;
      final sent = finalMsgs.firstWhere((m) => m.id == id);
      expect(sent.sending, false);
      expect(sent.contact, true);
    });

    test('failure removes pending bubble', () async {
      final c = await setup();
      share.answer = const Err(NetworkFailure('offline'));
      final f = c
          .read(messagesProvider.notifier)
          .sendContact(const SharedContact(name: 'Ann Lee', phone: '+90 555'));
      await until(() => share.calls.isNotEmpty);
      final id = share.calls.single.$2;
      final msgs = c.read(messagesProvider).requireValue;
      expect(msgs.any((m) => m.id == id && m.sending), true);
      share.gate!.complete();
      final result = await f;
      expect(result, isA<Err<void>>());
      expect((result as Err<void>).failure, isA<NetworkFailure>());
      final finalMsgs = c.read(messagesProvider).requireValue;
      expect(finalMsgs.any((m) => m.id == id), false);
    });

    test('not sendable chat returns DeniedFailure', () async {
      share = FakeContactShare();
      final c = await make(share: share);
      c.listen(messagesProvider, (_, _) {});
      // No conversation opened
      final result = await c
          .read(messagesProvider.notifier)
          .sendContact(const SharedContact(name: 'Ann Lee', phone: '+90 555'));
      expect(result, isA<Err<void>>());
      expect((result as Err<void>).failure, isA<DeniedFailure>());
      expect(share.calls.isEmpty, true);
    });

    test('invalid contact returns DeniedFailure and no bubble', () async {
      final c = await setup();
      final result = await c
          .read(messagesProvider.notifier)
          .sendContact(const SharedContact(name: '', phone: '12'));
      expect(result, isA<Err<void>>());
      expect((result as Err<void>).failure, isA<DeniedFailure>());
      expect(share.calls.isEmpty, true);
      final msgs = c.read(messagesProvider).requireValue;
      expect(msgs.any((m) => m.contact), false);
    });
  });
}
