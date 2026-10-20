import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/file_attachment.dart';
import '../../domain/link_preview.dart';
import '../../domain/message.dart';
import '../../domain/shared_location.dart';
import 'store_database.dart';

/// Maps a domain [Message] to a [MessagesCompanion].
MessagesCompanion messageToCompanion(Message m) {
  final extraMap = <String, Object?>{};
  if (m.attachmentPath != null) extraMap['ap'] = m.attachmentPath;
  if (m.stickerId != null) extraMap['st'] = m.stickerId;
  if (m.albumCard) extraMap['ac'] = true;
  if (m.albumId != null) extraMap['ai'] = m.albumId;
  if (m.location?.lat != null && m.location?.lng != null) {
    extraMap['lat'] = m.location!.lat;
    extraMap['lng'] = m.location!.lng;
  }
  if (m.linkPreview != null) extraMap['lp'] = m.linkPreview!.toJson();
  if (m.adminMsg != null) extraMap['am'] = m.adminMsg;
  if (m.sealed != null) extraMap['sh'] = m.sealed;
  if (m.file != null) {
    final file = m.file!;
    final fileMap = <String, Object?>{
      'n': file.name,
      'm': file.mime,
      's': file.size,
    };
    if (file.durationMs != null) fileMap['d'] = file.durationMs;
    if (file.waveform != null) fileMap['w'] = file.waveform;
    if (file.transcript != null) fileMap['t'] = file.transcript;
    extraMap['f'] = fileMap;
  }

  final extraJson = extraMap.isEmpty ? null : jsonEncode(extraMap);

  return MessagesCompanion(
    id: Value(m.id),
    conversationId: Value(m.conversationId),
    senderId: Value(m.senderId),
    body: Value(m.body),
    createdAt: Value(m.createdAt.microsecondsSinceEpoch),
    editedAt: Value(m.editedAt?.microsecondsSinceEpoch),
    deleted: Value(switch (m.deletion) {
      MessageDeletion.vanished => 'vanished',
      MessageDeletion.placeholder => 'placeholder',
      _ => null,
    }),
    deletedBy: Value(m.deletedBy),
    replyTo: Value(m.replyTo),
    photoGroup: Value(m.photoGroup),
    extra: Value(extraJson),
    forwarded: Value(m.forwarded),
    poll: Value(m.poll),
    contact: Value(m.contact),
    bodyFolded: Value(foldSearch(m.body)),
  );
}

/// Maps a [StoredMessageRow] to a domain [Message].
Message messageFromRow(StoredMessageRow r) {
  final x = r.extra == null
      ? const <String, Object?>{}
      : jsonDecode(r.extra!) as Map<String, Object?>;

  return Message(
    id: r.id,
    conversationId: r.conversationId,
    senderId: r.senderId,
    body: r.body,
    createdAt: DateTime.fromMicrosecondsSinceEpoch(r.createdAt),
    attachmentPath: x['ap'] as String?,
    replyTo: r.replyTo,
    forwarded: r.forwarded,
    poll: r.poll,
    contact: r.contact,
    photoGroup: r.photoGroup,
    stickerId: x['st'] as String?,
    albumCard: x['ac'] == true,
    albumId: x['ai'] as String?,
    editedAt: r.editedAt == null
        ? null
        : DateTime.fromMicrosecondsSinceEpoch(r.editedAt!),
    deletion: switch (r.deleted) {
      'vanished' => MessageDeletion.vanished,
      'placeholder' => MessageDeletion.placeholder,
      _ => null,
    },
    deletedBy: r.deletedBy,
    location: SharedLocation.fromRow(
      lat: (x['lat'] as num?)?.toDouble(),
      lng: (x['lng'] as num?)?.toDouble(),
      body: r.body,
    ),
    file: x['f'] == null
        ? null
        : AttachedFile(
            name: (x['f'] as Map)['n'] as String,
            mime: (x['f'] as Map)['m'] as String? ?? 'application/octet-stream',
            size: (x['f'] as Map)['s'] as int? ?? 0,
            durationMs: (x['f'] as Map)['d'] as int?,
            waveform: (x['f'] as Map)['w'] as String?,
            transcript: (x['f'] as Map)['t'] as String?,
          ),
    linkPreview: x['lp'] == null ? null : LinkPreview.fromJson(x['lp']),
    adminMsg: (x['am'] as Map?)?.cast<String, dynamic>(),
    sealed: x['sh'] as String?,
  );
}
