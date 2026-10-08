import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/postgrest_retry.dart';
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
    void Function(double fraction)? onProgress,
  }) async {
    final me = _client.auth.currentUser?.id;
    if (me == null) return const Err(DeniedFailure());

    try {
      final path = '$conversationId/${file.id}';

      // A video's small jpeg picture is stored next to it as `<path>.t`
      // (its own server rule lets whoever can read the video read it).
      final thumb = file.thumbPath;
      if (thumb != null) await _upload('$path.t', File(thumb), null);
      await _upload(path, File(file.path), onProgress);

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
              if (file.durationMs != null)
                'attachment_duration_ms': file.durationMs,
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
            .single()
            .retriedOnce();
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

  /// Uploads [file] to the private `attachments` bucket at [path], streaming
  /// so [onProgress] can report 0..1 (the storage client has no progress
  /// callback). Always octet-stream (MultipartFile's default): the bucket
  /// serves objects as-is, so a scripted type must never be stored; the real
  /// type travels in attachment_mime. An object that is already there from an
  /// earlier attempt of the same send (409) is success.
  Future<void> _upload(
    String path,
    File file,
    void Function(double fraction)? onProgress,
  ) async {
    final client = _http();
    try {
      final total = await file.length();
      var sent = 0;
      final request =
          http.MultipartRequest(
              'POST',
              Uri.parse('${_client.storage.url}/object/attachments/$path'),
            )
            ..headers.addAll(_client.storage.headers)
            ..headers['x-upsert'] = 'false'
            ..fields['cacheControl'] = '3600'
            ..files.add(
              http.MultipartFile(
                '',
                file.openRead().map((chunk) {
                  sent += chunk.length;
                  if (total > 0) onProgress?.call(sent / total);
                  return chunk;
                }),
                total,
                filename: file.path,
              ),
            );
      final response = await http.Response.fromStream(
        await client.send(request),
      );
      if (response.statusCode >= 200 && response.statusCode < 300) return;
      String? code;
      var message = response.body;
      try {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) {
          code = data['statusCode']?.toString();
          message = data['message'] as String? ?? message;
        }
      } catch (_) {}
      code ??= '${response.statusCode}';
      if (code == '409') return;
      throw StorageException(message, statusCode: code);
    } finally {
      client.close();
    }
  }

  @override
  Future<Result<void>> download(
    String attachmentPath,
    String destPath, {
    void Function(double fraction)? onProgress,
    int? expectedSize,
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
      if (expectedSize != null && await part.length() != expectedSize) {
        await part.delete();
        return const Err(NetworkFailure('This file is not available.'));
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
        StorageException(:final statusCode)
            when statusCode == '400' || statusCode == '404' =>
          const NetworkFailure('This file is not available.'),
        _ => readableFailure(e),
      });
    } finally {
      client.close();
    }
  }
}
