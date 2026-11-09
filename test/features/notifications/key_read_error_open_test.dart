// The two notification openers when the phone's key storage answers with an
// error: reactionOpener (main isolate, reaction pushes) and peekMain (the
// Kotlin PeekRunner seam on com.esd.sis/peek). Only the platform sides are
// faked: the secure-storage channel (test/support/secure_channel_fake.dart)
// and path_provider. Contract: no throw; the reaction opener gives null; the
// peek answers 'take' and then 'done' with no text and reason
// other:PlatformException; nothing is written or deleted. From the contract.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/data/push_peek_entry.dart';
import 'package:sis/features/notifications/data/reaction_opener.dart';
import 'package:sis/features/notifications/domain/reaction_push.dart';

import '../../support/secure_channel_fake.dart';

const _pickleName = 'sis.olm.pickle.key';
const _storeName = 'sis.store.key';
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _me = '0a11ce00-0000-4000-8000-00000000a11c';
const _peer = '0b0b0000-0000-4000-8000-000000000b0b';
const _conv = 'c0c0c0c0-0000-4000-8000-0000000c0c01';
const _msg = 'aaaa0001-0000-4000-8000-00000000aaaa';

const ReactionPush _push = (
  userId: _me,
  conversationId: _conv,
  messageId: _msg,
  reactorId: _peer,
  emoji: null,
  quote: null,
  quoteKind: null,
  ciphertext: 'AwogQUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo',
  olmType: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SecureChannelFake kc;
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() async {
    kc = SecureChannelFake()..install();
    kc.put(null, _storeName, 'a1' * 32);
    kc.put(null, _pickleName, '0f' * 32);
    final dir = await Directory.systemTemp.createTemp('sis-keyerr-');
    addTearDown(() => dir.delete(recursive: true));
    m.setMockMethodCallHandler(_pathChannel, (_) async => dir.path);
    addTearDown(() => m.setMockMethodCallHandler(_pathChannel, null));
  });

  group('5 reactionOpener', () {
    for (final (name, broken) in [
      ('the store key read throws', _storeName),
      ('the pickle key read throws', _pickleName),
    ]) {
      test('$name: null, no throw, nothing changed', () async {
        kc.failRead = (_, key) => key == broken;
        expect(await reactionOpener(null)(_push), isNull);
        expect(
          kc.calls.where((c) => c.key == broken && c.method == 'read'),
          isNotEmpty,
          reason: 'fixture: the broken key was read',
        );
        expect(kc.changes, isEmpty);
      });
    }
  });

  group('6 peekMain', () {
    Future<Map<Object?, Object?>> runPeek(Map<String, String> take) async {
      var took = 0;
      Map<Object?, Object?>? done;
      m.setMockMethodCallHandler(peekChannel, (c) async {
        if (c.method == 'take') {
          took++;
          return take;
        }
        if (c.method == 'done') done = c.arguments as Map<Object?, Object?>;
        return null;
      });
      addTearDown(() => m.setMockMethodCallHandler(peekChannel, null));
      await peekMain();
      expect(took, 1, reason: "'take' answered");
      expect(done, isNotNull, reason: "'done' always answered");
      return done!;
    }

    final message = {
      'user_id': _me,
      'conversation_id': _conv,
      'message_id': _msg,
      'ct': _push.ciphertext!,
      'ot': '1',
      'budget_ms': '3000',
    };
    final reaction = {...message, 'kind': 'reaction', 'reactor_id': _peer};

    for (final (kind, take) in [('message', message), ('reaction', reaction)]) {
      for (final (name, broken) in [
        ('store key', _storeName),
        ('pickle key', _pickleName),
      ]) {
        test("$kind push, the $name read throws: 'done' with no text, "
            'reason other:PlatformException, nothing changed', () async {
          kc.failRead = (_, key) => key == broken;
          final done = await runPeek(take);
          expect(done['text'], isNull);
          expect(done['reason'], 'other:PlatformException');
          expect(kc.changes, isEmpty);
        });
      }
    }
  });
}
