import 'dart:async';
import 'dart:developer';

import 'package:flutter/services.dart';

import '../domain/encrypted_reply.dart';

/// [EncryptedReplyIntake] over the platform channel `sis/encrypted_reply` to the
/// host app (MainActivity.kt on Android, AppDelegate.swift on iOS). The host
/// answers `take` with a list of maps with String values 'id',
/// 'conversation_id', 'user_id' and 'text'; it calls `arrived` on the channel
/// when a reply reaches the already running app. Twin of the share intake: thin
/// on purpose, verified on a device. The text and ids are never logged.
final class MethodChannelEncryptedReply implements EncryptedReplyIntake {
  /// Creates the intake; [channel] is the seam a test overrides.
  MethodChannelEncryptedReply({
    MethodChannel channel = const MethodChannel('sis/encrypted_reply'),
    // ignore: prefer_initializing_formals
  }) : _channel = channel {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final StreamController<void> _arrivals = StreamController<void>.broadcast();

  @override
  Stream<void> get arrivals => _arrivals.stream;

  Future<void> _onCall(MethodCall call) async {
    if (call.method == 'arrived') _arrivals.add(null);
  }

  @override
  Future<List<PendingReply>> take() async {
    final List<Object?>? raw;
    try {
      raw = await _channel.invokeListMethod<Object?>('take');
    } on PlatformException {
      log('encrypted reply intake failed', name: 'sis.chat');
      return const [];
    } on MissingPluginException {
      log('encrypted reply intake failed', name: 'sis.chat');
      return const [];
    }
    if (raw == null) return const [];
    final result = <PendingReply>[];
    for (final entry in raw) {
      if (entry is! Map<Object?, Object?>) continue;
      final id = entry['id'];
      final conversationId = entry['conversation_id'];
      final userId = entry['user_id'];
      final text = entry['text'];
      if (id is! String || id.isEmpty) continue;
      if (conversationId is! String || conversationId.isEmpty) continue;
      if (userId is! String || userId.isEmpty) continue;
      if (text is! String || text.isEmpty) continue;
      result.add(
        PendingReply(
          id: id,
          conversationId: conversationId,
          userId: userId,
          text: text,
        ),
      );
    }
    return result;
  }
}
