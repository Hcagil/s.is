import 'dart:convert';

import 'file_attachment.dart';
import 'shared_location.dart';
import 'video.dart';

/// One queued send, as saved: a text, a file, a video not yet shrunk, or a place.
final class QueuedRecord {
  /// Creates a queued record with the given properties.
  const QueuedRecord({
    required this.id,
    required this.conversationId,
    required this.createdAt,
    this.body = '',
    this.replyTo,
    this.file,
    this.video,
    this.location,
  });

  /// The ID of the message that will be sent (also file.id / video.id).
  final String id;

  /// The conversation ID.
  final String conversationId;

  /// When this record was created.
  final DateTime createdAt;

  /// The typed text of a text send, '' otherwise.
  final String body;

  /// The ID of the message answered, or null.
  final String? replyTo;

  /// A file or an already shrunk video, or null.
  final PickedFile? file;

  /// A video still to be shrunk, or null.
  final VideoSource? video;

  /// A place to send, or null.
  final SharedLocation? location;
}

/// Encodes a list of queued records into a JSON string.
String encodeQueue(List<QueuedRecord> records) {
  final List<Map<String, Object?>> json = [];
  for (final record in records) {
    final Map<String, Object?> map = {
      'id': record.id,
      'conversationId': record.conversationId,
      'createdAt': record.createdAt.millisecondsSinceEpoch,
      'body': record.body,
    };
    if (record.replyTo != null) {
      map['replyTo'] = record.replyTo!;
    }
    if (record.file != null) {
      final f = record.file!;
      final fileMap = <String, Object?>{
        'id': f.id,
        'path': f.path,
        'name': f.name,
        'mime': f.mime,
        'size': f.size,
      };
      if (f.durationMs != null) {
        fileMap['durationMs'] = f.durationMs!;
      }
      if (f.thumbPath != null) {
        fileMap['thumbPath'] = f.thumbPath!;
      }
      if (f.waveform != null) {
        fileMap['waveform'] = f.waveform!;
      }
      if (f.transcript != null) {
        fileMap['transcript'] = f.transcript!;
      }
      map['file'] = fileMap;
    } else if (record.video != null) {
      final v = record.video!;
      final videoMap = <String, Object?>{
        'id': v.id,
        'path': v.path,
        'name': v.name,
        'size': v.size,
        'durationMs': v.durationMs,
        'width': v.width,
        'height': v.height,
        'thumbPath': v.thumbPath,
      };
      map['video'] = videoMap;
    }
    final loc = record.location;
    if (loc != null) {
      map['location'] = <String, Object?>{
        'lat': loc.lat,
        'lng': loc.lng,
        'name': loc.name,
        'address': loc.address,
      };
    }
    json.add(map);
  }
  return jsonEncode(json);
}

/// Decodes a JSON string into a list of queued records.
List<QueuedRecord> decodeQueue(String? json) {
  if (json == null || json.isEmpty) {
    return const [];
  }
  try {
    final List<dynamic> raw = jsonDecode(json) as List<dynamic>;
    final List<QueuedRecord> result = [];
    for (final item in raw) {
      try {
        if (item is! Map<String, dynamic>) continue;
        final id = item['id'] as String;
        final conversationId = item['conversationId'] as String;
        final createdAt = DateTime.fromMillisecondsSinceEpoch(
          item['createdAt'] as int,
        );
        final body = item['body'] as String? ?? '';
        final replyTo = item['replyTo'] as String?;
        PickedFile? file;
        VideoSource? video;
        SharedLocation? location;
        if (item.containsKey('file')) {
          final f = item['file'] as Map<String, dynamic>;
          file = PickedFile(
            id: f['id'] as String,
            path: f['path'] as String,
            name: f['name'] as String,
            mime: f['mime'] as String,
            size: f['size'] as int,
            durationMs: f['durationMs'] as int?,
            thumbPath: f['thumbPath'] as String?,
            waveform: f['waveform'] as String?,
            transcript: f['transcript'] as String?,
          );
        } else if (item.containsKey('video')) {
          final v = item['video'] as Map<String, dynamic>;
          video = VideoSource(
            id: v['id'] as String,
            path: v['path'] as String,
            name: v['name'] as String,
            size: v['size'] as int,
            durationMs: v['durationMs'] as int,
            width: v['width'] as int,
            height: v['height'] as int,
            thumbPath: v['thumbPath'] as String,
          );
        }
        if (item.containsKey('location')) {
          final l = item['location'] as Map<String, dynamic>;
          location = SharedLocation(
            lat: (l['lat'] as num).toDouble(),
            lng: (l['lng'] as num).toDouble(),
            name: l['name'] as String,
            address: l['address'] as String? ?? '',
          );
        }
        result.add(
          QueuedRecord(
            id: id,
            conversationId: conversationId,
            createdAt: createdAt,
            body: body,
            replyTo: replyTo,
            file: file,
            video: video,
            location: location,
          ),
        );
      } catch (_) {
        // Skip invalid entries
        continue;
      }
    }
    return result;
  } catch (_) {
    return const [];
  }
}

/// Where the send queue is kept on the phone, per member.
abstract interface class SendQueueStore {
  /// The records saved for [userId], oldest first; those whose file or video is gone from the phone are left out. Never throws: unreadable -> empty.
  Future<List<QueuedRecord>> load(String userId);

  /// Replaces what is saved for [userId]. Never throws.
  Future<void> save(String userId, List<QueuedRecord> records);

  /// Forgets everything saved for every member (sign-out).
  Future<void> clear();
}
