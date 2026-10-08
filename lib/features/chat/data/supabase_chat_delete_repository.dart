import 'dart:async';
import 'dart:developer';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/chat_delete_repository.dart';

/// [ChatDeleteRepository] backed by the `hide_chat` and `delete_direct_chat`
/// functions. The server checks who may call each.
final class SupabaseChatDeleteRepository implements ChatDeleteRepository {
  SupabaseChatDeleteRepository(this._client);

  final SupabaseClient _client;

  String? get _uid => _client.auth.currentUser?.id;

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  @override
  Future<Result<void>> hideChat(String conversationId) async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      await _client.rpc('hide_chat', params: {'conversation': conversationId});
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<void>> deleteDirectChat(String conversationId) async {
    final uid = _uid;
    if (uid == null) return const Err(DeniedFailure());
    try {
      final paths = await _client.rpc(
        'delete_direct_chat',
        params: {'conversation': conversationId},
      );
      if (paths is List && paths.isNotEmpty) {
        try {
          final files = List<String>.from(paths);
          // A video's thumbnail sits next to it as `<path>.t`; removing a
          // name that does not exist is harmless.
          await _client.storage.from('attachments').remove([
            ...files,
            for (final p in files) '$p.t',
          ]);
        } catch (e) {
          log(
            'deleteDirectChat: photo file removal failed: ${e.runtimeType}',
            name: 'sis.data',
            level: 900,
          );
        }
      }
      return const Ok(null);
    } catch (e) {
      return Err(_asFailure(e));
    }
  }
}
