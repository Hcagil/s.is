import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../domain/file_attachment.dart';
import '../domain/file_repository.dart';
import '../domain/message.dart';

/// [ChatFileRepository] backed by Supabase storage and messages table.
final class SupabaseChatFileRepository implements ChatFileRepository {
  SupabaseChatFileRepository(this._client, {http.Client Function()? httpClient})
    : _http = httpClient ?? http.Client.new;

  final SupabaseClient _client;
  final http.Client Function() _http;

  @override
  Future<Result<Message>> send(
    String conversationId,
    PickedFile file, {
    String? replyTo,
  }) async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return const Err(DeniedFailure());

    try {
      final path = '$conversationId/${file.id}';

      try {
        await _client.storage
            .from('attachments')
            .upload(
              path,
              File(file.path),
              fileOptions: FileOptions(contentType: file.mime),
            );
      } on StorageException catch (e) {
        if (e.statusCode != '409') rethrow;
      }

      DateTime createdAt;
      try {
        final row = await _client
            .from('messages')
            .insert({
              'id': file.id,
              'conversation_id': conversationId,
              'sender_id': me,
              'body': '',
              'attachment_path': path,
              'attachment_name': file.name,
              'attachment_mime': file.mime,
              'attachment_size': file.size,
              'reply_to': replyTo,
            })
            .select('id, created_at')
            .single();
        createdAt = DateTime.parse(row['created_at'] as String).toLocal();
      } on PostgrestException catch (e) {
        if (e.code != '23505') rethrow;
        final row = await _client
            .from('messages')
            .select('created_at')
            .eq('id', file.id)
            .single();
        createdAt = DateTime.parse(row['created_at'] as String).toLocal();
      }

      return Ok(
        Message(
          id: file.id,
          conversationId: conversationId,
          senderId: me,
          body: '',
          createdAt: createdAt,
          attachmentPath: path,
          replyTo: replyTo,
          file: file.attached,
        ),
      );
    } catch (e) {
      return Err(switch (e) {
        PostgrestException(:final code) when code == '42501' =>
          const DeniedFailure(),
        StorageException(:final statusCode)
            when statusCode == '401' || statusCode == '403' =>
          const DeniedFailure(),
        _ => readableFailure(e),
      });
    }
  }

  @override
  Future<Result<void>> download(
    String attachmentPath,
    String destPath, {
    void Function(double fraction)? onProgress,
  }) async {
    final client = _http();
    final part = File('$destPath.part');
    try {
      final url = await _client.storage
          .from('attachments')
          .createSignedUrl(attachmentPath, 600);
      final response = await client.send(http.Request('GET', Uri.parse(url)));
      if (response.statusCode != 200) {
        return const Err(NetworkFailure('This file is not available.'));
      }
      final total = response.contentLength;
      var received = 0;
      final sink = part.openWrite();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          if (total != null && total > 0) onProgress?.call(received / total);
        }
      } finally {
        await sink.close();
      }
      await part.rename(destPath);
      return const Ok(null);
    } catch (e) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      return Err(switch (e) {
        StorageException(:final statusCode)
            when statusCode == '401' || statusCode == '403' =>
          const DeniedFailure(),
        _ => readableFailure(e),
      });
    } finally {
      client.close();
    }
  }
}
