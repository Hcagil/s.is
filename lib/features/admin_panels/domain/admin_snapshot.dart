import 'admin_dashboard.dart';
import 'admin_item.dart';
import 'admin_models.dart';

/// What the four panels show, built from the computer's items.
final class AdminSnapshot {
  const AdminSnapshot._(this._items, this.cursor, this.truncated);
  static const AdminSnapshot empty = AdminSnapshot._({}, 0, false);
  final Map<String, AdminItem> _items;

  /// The computer's cursor of the newest change in this snapshot.
  final int cursor;

  /// True when the computer left older messages out.
  final bool truncated;

  /// A complete snapshot: REPLACES everything (items with removed == true are ignored).
  factory AdminSnapshot.full(
    List<AdminItem> items, {
    required int cursor,
    required bool truncated,
  }) {
    final map = <String, AdminItem>{};
    for (final item in items) {
      if (item.removed) continue;
      map[item.id] = item;
    }
    return AdminSnapshot._(map, cursor, truncated);
  }

  /// Applies a delta to this snapshot.
  AdminSnapshot withDelta(List<AdminItem> items, int newCursor) {
    final map = Map<String, AdminItem>.of(_items);
    for (final item in items) {
      if (item.removed) {
        map.remove(item.id);
      } else {
        map[item.id] = item;
      }
    }
    return AdminSnapshot._(map, newCursor, truncated);
  }

  /// Questions in this snapshot.
  List<AdminQuestion> get questions => _items.values
      .where((item) => item.kind == 'question')
      .map((item) => AdminQuestion.fromFields(item.fields))
      .toList();

  /// Tasks in this snapshot.
  List<AdminTask> get tasks => _items.values
      .where((item) => item.kind == 'task')
      .map((item) => AdminTask.fromFields(item.fields))
      .toList();

  /// Cards in this snapshot, by id.
  List<AdminCard> get cards =>
      _items.values
          .where((item) => item.kind == 'card')
          .map((item) => AdminCard.fromFields(item.fields))
          .where((c) => c.id.isNotEmpty)
          .toList()
        ..sort((a, b) => a.id.compareTo(b.id));

  /// Conversations in this snapshot, newest first.
  List<AdminConversation> get conversations {
    final list = _items.values
        .where((item) => item.kind == 'talk' && item.fields['conv'] == true)
        .map((item) => AdminConversation.fromFields(item.fields))
        .toList();
    list.sort((a, b) => b.at.compareTo(a.at));
    return list;
  }

  /// Messages in this snapshot, oldest first.
  List<AdminMessage> get messages {
    final list = _items.values
        .where((item) => item.kind == 'talk' && item.fields['conv'] != true)
        .map((item) => AdminMessage.fromFields(item.fields))
        .toList();
    list.sort((a, b) => a.at.compareTo(b.at));
    return list;
  }

  /// The dashboard item, if present.
  AdminDashboard? get dashboard {
    final item = _items['dashboard'];
    if (item == null) return null;
    return AdminDashboard.fromFields(item.fields);
  }

  Map<String, Object?> toJson() => {
    'cursor': cursor,
    'truncated': truncated,
    'items': [for (final i in _items.values) i.toJson()],
  };

  static AdminSnapshot? tryFromJson(Object? raw) {
    try {
      if (raw is! Map) return null;
      final itemsRaw = raw['items'];
      if (itemsRaw is! List) return null;
      final cursor = raw['cursor'];
      if (cursor is! int) return null;
      final items = <AdminItem>[];
      for (final entry in itemsRaw) {
        if (entry is Map) {
          items.add(AdminItem.fromJson(Map<String, Object?>.from(entry)));
        }
      }
      final truncated = raw['truncated'] == true;
      return AdminSnapshot.full(items, cursor: cursor, truncated: truncated);
    } catch (_) {
      return null;
    }
  }
}
