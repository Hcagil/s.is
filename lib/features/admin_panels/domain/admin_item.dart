import 'dart:convert';

import 'admin_answer.dart';

/// One entry of the computer's export (plaintext, after decryption).
final class AdminItem {
  const AdminItem({
    required this.id,
    required this.kind,
    required this.seq,
    required this.removed,
    required this.fields,
  });

  /// `q:<Q-id>`, `t:<T-id>`, `m:<msg id>`, `c:<conv id>` or `dashboard`.
  final String id;

  /// talk | question | task | dashboard
  final String kind;

  final int seq;

  /// True for an item that left the lists; its [fields] are empty.
  final bool removed;

  final Map<String, Object?> fields;

  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind,
    'seq': seq,
    'removed': removed,
    'fields': fields,
  };

  factory AdminItem.fromJson(Map<String, Object?> j) {
    final id = j['id'] is String ? j['id'] as String : '';
    final kind = j['kind'] is String ? j['kind'] as String : '';
    final seq = j['seq'] is int ? j['seq'] as int : 0;
    final removed = j['removed'] == true;
    final fields = j['fields'] is Map
        ? Map<String, Object?>.from(j['fields'] as Map)
        : const <String, Object?>{};
    return AdminItem(
      id: id,
      kind: kind,
      seq: seq,
      removed: removed,
      fields: fields,
    );
  }
}

/// A decrypted message from the computer.
sealed class AdminDown {
  const AdminDown();
}

/// One part of a full snapshot: {"t":"snapshot","id":"e1s5","part":1,"parts":3,"cursor":N,"truncated":false,"items":[...]}.
final class AdminSnapshotPart extends AdminDown {
  const AdminSnapshotPart({
    required this.id,
    required this.part,
    required this.parts,
    required this.cursor,
    required this.truncated,
    required this.items,
    this.results = const [],
  });
  final String id;
  final int part;
  final int parts;
  final int cursor;
  final bool truncated;
  final List<AdminItem> items;

  /// Answer results (part 1 only).
  final List<AdminAnswerResult> results;
}

/// A change since the last cursor: {"t":"items","cursor":N,"items":[...]}.
final class AdminDelta extends AdminDown {
  const AdminDelta({
    required this.cursor,
    required this.items,
    this.results = const [],
  });
  final int cursor;
  final List<AdminItem> items;
  final List<AdminAnswerResult> results;
}

/// Reads one decrypted message. Never throws: bad JSON, an unknown "t", or a wrong shape gives null.
AdminDown? parseDown(String json) {
  try {
    final root = jsonDecode(json);
    if (root is! Map) return null;
    final t = root['t'];
    if (t is! String) return null;

    if (t == 'snapshot') {
      final id = root['id'];
      if (id is! String || id.isEmpty) return null;
      final part = root['part'];
      final parts = root['parts'];
      if (part is! int || parts is! int) return null;
      if (part < 1 || parts < 1 || part > parts || parts > 1000) return null;
      final cursor = root['cursor'];
      return AdminSnapshotPart(
        id: id,
        part: part,
        parts: parts,
        cursor: cursor is int ? cursor : 0,
        truncated: root['truncated'] == true,
        items: _parseItems(root['items']),
        results: parseAnswerResults(root['results']),
      );
    }

    if (t == 'items') {
      final cursor = root['cursor'];
      return AdminDelta(
        cursor: cursor is int ? cursor : 0,
        items: _parseItems(root['items']),
        results: parseAnswerResults(root['results']),
      );
    }

    return null;
  } on FormatException {
    return null;
  }
}

List<AdminItem> _parseItems(Object? raw) {
  if (raw is! List) return const [];

  final result = <AdminItem>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final id = entry['id'];
    if (id is! String || id.isEmpty) continue;
    final kind = entry['kind'];
    if (kind is! String) continue;
    final seq = entry['seq'];
    final fieldsRaw = entry['fields'];
    result.add(
      AdminItem(
        id: id,
        kind: kind,
        seq: seq is int ? seq : 0,
        removed: entry['removed'] == true,
        fields: fieldsRaw is Map
            ? Map<String, Object?>.from(fieldsRaw)
            : const {},
      ),
    );
  }
  return result;
}
