// Image attachments, written from the contract: what a member can do, what
// they see, and what the repository is asked for — never how any of it is
// built.
//
// The outcome this file exists for is the cancelled picker. "The member backed
// out" is not a failure, and a slice that treats it as one puts an error in
// front of somebody who did nothing wrong and throws away what they had typed.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/auth/domain/session_state.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/presentation/message_screen.dart';

import '../../support/fakes.dart';

const me = Member(userId: 'u1', displayName: 'Maya');
const bob = Member(userId: 'u2', displayName: 'Bob');

Message msg(
  String id, {
  String body = 'hi',
  String from = 'u1',
  String? attachment,
  int minute = 0,
}) => Message(
  id: id,
  conversationId: 'c1',
  senderId: from,
  body: body,
  createdAt: DateTime.utc(2026, 9, 22, 12, minute),
  attachmentPath: attachment,
);

class _SignedIn extends SessionController {
  @override
  Future<SessionState> build() async => const Allowed(me);
}

Future<ProviderContainer> scope(ChatFake chat, AttachmentSource picker) =>
    settled(
      ProviderContainer.test(
        overrides: [
          chatRepositoryProvider.overrideWithValue(chat),
          presenceRepositoryProvider.overrideWithValue(PresenceFake()),
          attachmentSourceProvider.overrideWithValue(picker),
          sessionControllerProvider.overrideWith(_SignedIn.new),
        ],
      ),
    );

Future<ProviderContainer> pump(
  WidgetTester tester,
  ChatFake chat,
  AttachmentSource picker,
) async {
  final container = await scope(chat, picker);
  container.read(openConversationProvider.notifier).open('c1');
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: MessageScreen(title: 'Bob')),
    ),
  );
  await tester.pump();
  // A photo shows a spinner until it decodes, which the fake clock never
  // settles; let the engine decode for real.
  await settleImages(tester);
  return container;
}

String composerText(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(const ValueKey('composer-field')),
        matching: find.byType(EditableText),
      ),
    )
    .controller
    .text;

/// Any visible text of real length: a reason, not a blank space.
final reason = find.byWidgetPredicate(
  (w) => w is Text && (w.data ?? '').trim().length >= 10,
);

void expectNoRawException(WidgetTester tester) {
  final leaked = find.byWidgetPredicate((w) {
    final data = w is Text ? (w.data ?? '') : '';
    return data.contains('Instance of') ||
        data.contains('Failure(') ||
        data.contains('Exception');
  });
  expect(leaked, findsNothing, reason: 'a raw exception string reached the UI');
}

void main() {
  setUpAll(() => HttpOverrides.global = ImageServer());
  tearDownAll(() => HttpOverrides.global = null);

  group('MessagesController.sendImage', () {
    test('a cancelled picker is null — not a failure', () async {
      final chat = ChatFake();
      final picker = PickerFake.cancels();
      final c = await scope(chat, picker);
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);

      final result = await c.read(messagesProvider.notifier).sendImage();

      expect(
        result,
        isNull,
        reason: 'backing out of the picker is not an error to report',
      );
      expect(picker.calls, 1);
      expect(
        chat.sentImages,
        isEmpty,
        reason: 'nothing was chosen, so nothing may be uploaded',
      );
    });

    test('a picker that throws becomes a provider failure', () async {
      final chat = ChatFake();
      final c = await scope(
        chat,
        PickerFake.throwsError(StateError('no photo permission')),
      );
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);

      final result = await c.read(messagesProvider.notifier).sendImage();

      expect(result, isA<Err<Message>>());
      expect((result! as Err<Message>).failure, isA<ProviderFailure>());
      expect(
        (result as Err<Message>).failure.message.trim(),
        isNotEmpty,
        reason: 'a failure with no reason cannot be shown to anybody',
      );
      expect(chat.sentImages, isEmpty);
    });

    test('a chosen image is uploaded with its caption and appended', () async {
      final chat = ChatFake();
      final c = await scope(chat, PickerFake.returns(pickedPng()));
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);

      final result = await c
          .read(messagesProvider.notifier)
          .sendImage(body: 'look at this');

      expect(result, isA<Ok<Message>>());
      final sent = chat.sentImages.single;
      expect(sent.conversationId, 'c1');
      expect(sent.body, 'look at this');
      expect(
        sent.image.bytes,
        pngBytes,
        reason: 'the bytes the picker returned must be the bytes uploaded',
      );
      expect(sent.image.contentType, 'image/png');

      final shown = c.read(messagesProvider).requireValue;
      expect(
        shown.map((m) => m.id),
        contains((result! as Ok<Message>).value.id),
        reason:
            'the sender must see their own image without waiting for '
            'the Realtime echo',
      );
      expect(shown.last.hasAttachment, isTrue);
    });

    test('an image with no caption is allowed', () async {
      final chat = ChatFake();
      final c = await scope(chat, PickerFake.returns(pickedPng()));
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);

      final result = await c.read(messagesProvider.notifier).sendImage();

      expect(result, isA<Ok<Message>>());
      expect(chat.sentImages.single.body, '');
      expect((result! as Ok<Message>).value.body, isEmpty);
      expect((result as Ok<Message>).value.hasAttachment, isTrue);
    });

    test('an upload the database would refuse comes back as Err', () async {
      final chat = ChatFake();
      // A bucket that accepts only four image types refuses this one; a fake
      // that accepts everything would let an unvalidated upload ship green.
      final c = await scope(
        chat,
        PickerFake.returns(pickedPng(contentType: 'application/pdf')),
      );
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);

      final result = await c.read(messagesProvider.notifier).sendImage();

      expect(result, isA<Err<Message>>());
      expect(
        c.read(messagesProvider).requireValue,
        isEmpty,
        reason: 'a refused upload must not be appended to the conversation',
      );
    });

    test(
      'a slow picker does not resolve before the member has chosen',
      () async {
        final chat = ChatFake();
        final c = await scope(
          chat,
          PickerFake.returns(
            pickedPng(),
            latency: const Duration(milliseconds: 120),
          ),
        );
        c.read(openConversationProvider.notifier).open('c1');
        await c.read(messagesProvider.future);

        var settled = false;
        final pending = c
            .read(messagesProvider.notifier)
            .sendImage()
            .whenComplete(() => settled = true);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(
          settled,
          isFalse,
          reason: 'the picker sheet is open; nothing has been chosen yet',
        );
        expect(chat.sentImages, isEmpty);

        expect(await pending, isA<Ok<Message>>());
        expect(settled, isTrue);
      },
    );

    test('attachmentUrl asks the repository for that exact path', () async {
      final chat = ChatFake()..store('c1/held.png');
      final c = await scope(chat, PickerFake.cancels());
      c.read(openConversationProvider.notifier).open('c1');
      await c.read(messagesProvider.future);

      final url = await c
          .read(messagesProvider.notifier)
          .attachmentUrl('c1/held.png');

      expect(url, isA<Ok<Uri>>());
      expect(chat.urlRequests, ['c1/held.png']);

      // A path the bucket holds nothing for is a refusal, not a URL.
      expect(
        await c.read(messagesProvider.notifier).attachmentUrl('c1/ghost.png'),
        isA<Err<Uri>>(),
      );
    });
  });

  group('composer', () {
    testWidgets('offers an attach button', (tester) async {
      await pump(tester, ChatFake(), PickerFake.cancels());
      expect(find.byKey(const ValueKey('composer-attach')), findsOneWidget);
    });

    testWidgets('cancelling shows no error and clears nothing', (tester) async {
      final chat = ChatFake();
      final picker = PickerFake.cancels();
      await pump(tester, chat, picker);

      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'a caption I typed',
      );
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('composer-attach')));
      await tester.pumpAndSettle();

      expect(picker.calls, 1, reason: 'the attach button never opened it');
      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'backing out of the picker is not an error',
      );
      expect(
        composerText(tester),
        'a caption I typed',
        reason: 'a cancelled pick must not throw away what was typed',
      );
      expect(chat.sentImages, isEmpty);
      expect(find.byKey(const ValueKey('attachment-image')), findsNothing);
      expectNoRawException(tester);

      // Still usable afterwards: cancelling must not leave it stuck.
      await tester.tap(find.byKey(const ValueKey('composer-attach')));
      await tester.pumpAndSettle();
      expect(picker.calls, 2);
    });

    testWidgets('a picker that fails shows its reason', (tester) async {
      final chat = ChatFake();
      await pump(
        tester,
        chat,
        PickerFake.throwsError(StateError('no photo permission')),
      );

      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'worth keeping',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-attach')));
      await tester.pumpAndSettle();

      expect(
        find.byType(SnackBar),
        findsOneWidget,
        reason: 'a failed pick must say so; a silent return is a defect',
      );
      expect(reason, findsAtLeastNWidgets(1));
      expect(
        composerText(tester),
        'worth keeping',
        reason: 'a failure must not throw away what was typed',
      );
      expect(chat.sentImages, isEmpty);
      expectNoRawException(tester);
      await tester.pumpAndSettle(const Duration(seconds: 6));
    });

    testWidgets('a failed upload shows its reason and keeps the caption', (
      tester,
    ) async {
      final chat = ChatFake()
        ..sendImageResult = const Err(
          NetworkFailure('the upload did not finish'),
        );
      await pump(tester, chat, PickerFake.returns(pickedPng()));

      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'worth keeping',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-attach')));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('the upload did not finish'),
        findsAtLeastNWidgets(1),
      );
      expect(composerText(tester), 'worth keeping');
      expectNoRawException(tester);
      await tester.pumpAndSettle(const Duration(seconds: 6));
    });

    testWidgets('a successful send clears the composer', (tester) async {
      final chat = ChatFake();
      await pump(tester, chat, PickerFake.returns(pickedPng()));

      await tester.enterText(
        find.byKey(const ValueKey('composer-field')),
        'look at this',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('composer-attach')));
      await settleImages(tester);

      expect(chat.sentImages.single.body, 'look at this');
      expect(composerText(tester), isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  group('an image message', () {
    testWidgets('renders the image and its caption', (tester) async {
      final chat = ChatFake()
        ..messagesResult = Ok([
          msg('m1', body: 'look at this', attachment: 'c1/photo.png'),
        ])
        ..store('c1/photo.png');
      await pump(tester, chat, PickerFake.cancels());

      expect(find.byKey(const ValueKey('message-m1')), findsOneWidget);
      expect(find.byKey(const ValueKey('attachment-image')), findsOneWidget);
      expect(find.text('look at this'), findsOneWidget);
      expect(
        chat.urlRequests,
        contains('c1/photo.png'),
        reason: 'the bucket is private; the path must be signed before use',
      );
    });

    testWidgets('an image with no caption renders without an empty bubble', (
      tester,
    ) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', body: '', attachment: 'c1/photo.png')])
        ..store('c1/photo.png');
      await pump(tester, chat, PickerFake.cancels());

      expect(find.byKey(const ValueKey('attachment-image')), findsOneWidget);
      expectNoRawException(tester);
    });

    testWidgets(
      'a URL that cannot be issued shows a reason, not a broken box',
      (tester) async {
        final chat = ChatFake()
          ..messagesResult = Ok([
            msg('m1', body: 'look at this', attachment: 'c1/photo.png'),
          ])
          // Deliberately NOT stored: the signed URL cannot be issued.
          ..attachmentUrlResult = const Err(
            NetworkFailure('the image is unavailable'),
          );
        await pump(tester, chat, PickerFake.cancels());

        expect(find.byKey(const ValueKey('message-m1')), findsOneWidget);
        expect(
          find.textContaining('the image is unavailable'),
          findsAtLeastNWidgets(1),
          reason: 'an attachment that cannot load must say why',
        );
        expect(
          find.byType(CircularProgressIndicator),
          findsNothing,
          reason: 'a failed attachment must not spin forever',
        );
        expectNoRawException(tester);
      },
    );

    testWidgets('a text-only message asks for no URL at all', (tester) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', body: 'just words')]);
      await pump(tester, chat, PickerFake.cancels());

      expect(find.text('just words'), findsOneWidget);
      expect(find.byKey(const ValueKey('attachment-image')), findsNothing);
      expect(chat.urlRequests, isEmpty);
    });

    testWidgets('an image arriving over Realtime renders too', (tester) async {
      final chat = ChatFake()
        ..messagesResult = Ok([msg('m1', body: 'first')])
        ..store('c1/incoming.png');
      await pump(tester, chat, PickerFake.cancels());

      chat.deliver(
        msg(
          'm2',
          body: '',
          from: bob.userId,
          attachment: 'c1/incoming.png',
          minute: 5,
        ),
      );
      await settleImages(tester);

      expect(find.byKey(const ValueKey('message-m2')), findsOneWidget);
      expect(find.byKey(const ValueKey('attachment-image')), findsOneWidget);
    });
  });

  group('the domain model', () {
    test('hasAttachment follows attachmentPath', () {
      expect(msg('m1').hasAttachment, isFalse);
      expect(msg('m1', attachment: 'c1/a.png').hasAttachment, isTrue);
    });

    test('a picked image carries the bytes it was made from', () {
      final image = PickedImage(
        bytes: Uint8List.fromList(const [1, 2, 3]),
        contentType: 'image/jpeg',
        extension: 'jpg',
      );
      expect(image.bytes, [1, 2, 3]);
      expect(image.contentType, 'image/jpeg');
      expect(image.extension, 'jpg');
    });
  });
}
