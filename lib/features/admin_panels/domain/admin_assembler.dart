import 'admin_item.dart';
import 'admin_snapshot.dart';

/// Collects the parts of one full snapshot (all parts share one id).
///
/// A part with a new id drops the half-finished snapshot; the snapshot is
/// returned only when parts 1..n of one id are all present.
final class AdminAssembler {
  String? _id;
  int? _parts;
  final Map<int, AdminSnapshotPart> _partsMap = {};

  /// Feeds one part. Returns the complete snapshot, or null while parts are missing or when the part is ignored.
  AdminSnapshot? addPart(AdminSnapshotPart p) {
    if (_id != null && _id != p.id) _clear();
    _id = p.id;
    if (_parts != null && _parts != p.parts) return null;
    _parts = p.parts;
    _partsMap[p.part] = p;
    if (_partsMap.length != p.parts) return null;

    final allItems = <AdminItem>[];
    var cursor = 0;
    var truncated = false;
    for (var i = 1; i <= p.parts; i++) {
      final part = _partsMap[i];
      if (part == null) return null;
      allItems.addAll(part.items);
      if (i == 1) cursor = part.cursor;
      if (part.truncated) truncated = true;
    }
    _clear();
    return AdminSnapshot.full(allItems, cursor: cursor, truncated: truncated);
  }

  /// Drops everything collected so far.
  void reset() => _clear();

  void _clear() {
    _id = null;
    _parts = null;
    _partsMap.clear();
  }
}
