import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../chat/data/store/store_key.dart';
import '../../chat/data/store/store_location.dart';
import '../../crypto/data/olm_peek.dart';
import '../../crypto/data/pickle_key.dart';

/// Channel to the Android PeekRunner (PeekRunner.kt).
const peekChannel = MethodChannel('com.esd.sis/peek');

/// Entry of the headless engine started for one encrypted push: asks Kotlin
/// for the push fields ('take' returns a Map with String keys user_id,
/// conversation_id, message_id, ct and ot (ot is a String like "0"), plus
/// optional sk and si: a pre-key push's sender key and id, never logged), peeks,
/// and always answers 'done' with a Map {text, reason, name, older}: the text, or null
/// plus a fixed reason code (never text, ids or keys), the chat partner's
/// name from the phone's own copy of the chat (null when unknown), and older (message id -> text) read from the store for the optional comma-joined 'older' ids of 'take' (in memory only). Never
/// throws. For kind 'reaction' (with reactor_id) it calls peekReaction instead and answers 'done' with emoji and quote (null text); that path writes nothing. It writes only through peekEncryptedText (see there): the opened text of a chat the phone already knows, into push_inbox, and only when 'take' carried budget_ms. 'done' is answered after that write has committed and its connection is closed.
@pragma('vm:entry-point')
Future<void> peekMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  String? text;
  String? reason;
  String? peerName;
  String? emoji;
  String? quote;
  Map<String, String> older = const {};
  try {
    final a = await peekChannel.invokeMapMethod<String, String>('take');
    // Push time Kotlin still allows when it answered 'take' (ms); the text is saved into the store only when enough is left.
    final budget = int.tryParse(a?['budget_ms'] ?? '');
    final took = Stopwatch()..start();
    final key = await StoreKey().read();
    final pickle = await PickleKey().read();
    if (a == null) {
      reason = 'no_args';
    } else if (key == null) {
      reason = 'no_store_key';
    } else if (pickle == null) {
      reason = 'no_pickle_key';
    } else {
      if (a['kind'] == 'reaction') {
        final r = await peekReaction(
          storePath: (await storeFile()).path,
          storeKeyHex: key,
          pickleKey: pickle,
          ownerId: a['user_id']!,
          conversationId: a['conversation_id']!,
          messageId: a['message_id']!,
          reactorId: a['reactor_id']!,
          ciphertext: a['ct']!,
          olmType: int.parse(a['ot']!),
          onFail: (r) => reason = r,
          onPeerName: (n) => peerName = n,
        );
        emoji = r?.emoji;
        quote = r?.quote;
      } else {
        text = await peekEncryptedText(
          storePath: (await storeFile()).path,
          storeKeyHex: key,
          pickleKey: pickle,
          ownerId: a['user_id']!,
          conversationId: a['conversation_id']!,
          messageId: a['message_id']!,
          ciphertext: a['ct']!,
          olmType: int.parse(a['ot']!),
          senderKey: a['sk'],
          senderId: a['si'],
          olderIds: (a['older'] ?? '')
              .split(',')
              .where((s) => s.isNotEmpty)
              .toList(),
          onFail: (r) => reason = r,
          onPeerName: (n) => peerName = n,
          onOlder: (o) => older = o,
          budgetLeftMs: budget == null
              ? null
              : () => budget - took.elapsedMilliseconds,
          // A fixed code, never text, ids or keys.
          onInbox: (c) => debugPrint('sis.peek inbox $c'),
        );
      }
    }
  } catch (e) {
    text = null; // any failure leaves the notification locked
    reason = 'other:${e.runtimeType}';
  }
  if (text != null || emoji != null) {
    reason = null;
  } else {
    reason ??= 'decrypt_fail';
  }
  if (kDebugMode) {
    debugPrint('sis.peek done reason=$reason older=${older.length}');
  }
  await peekChannel.invokeMethod<void>('done', {
    'text': text,
    'emoji': emoji,
    'quote': quote,
    'reason': reason,
    'name': peerName,
    'older': older,
  });
}
