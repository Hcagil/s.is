import 'dart:ui';

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
/// conversation_id, message_id, ct and ot (ot is a String like "0")), peeks,
/// and always answers 'done' with a Map {text, reason}: the text, or null plus
/// a fixed reason code (never text, ids or keys). Never throws; writes nothing.
@pragma('vm:entry-point')
Future<void> peekMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  String? text;
  String? reason;
  try {
    final a = await peekChannel.invokeMapMethod<String, String>('take');
    final key = await StoreKey().read();
    final pickle = await PickleKey().read();
    if (a == null) {
      reason = 'no_args';
    } else if (key == null) {
      reason = 'no_store_key';
    } else if (pickle == null) {
      reason = 'no_pickle_key';
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
        onFail: (r) => reason = r,
      );
    }
  } catch (e) {
    text = null; // any failure leaves the notification locked
    reason = 'other:${e.runtimeType}';
  }
  if (text != null) {
    reason = null;
  } else {
    reason ??= 'decrypt_fail';
  }
  await peekChannel.invokeMethod<void>('done', {
    'text': text,
    'reason': reason,
  });
}
