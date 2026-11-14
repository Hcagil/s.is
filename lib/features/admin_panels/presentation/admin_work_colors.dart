import 'package:flutter/material.dart';

import '../domain/admin_dashboard.dart';

/// State dot colours, the same hues the computer CLI panel uses: running green, shell yellow, stale red; each keeps 3:1 against the light and dark backgrounds.
const Map<String, Color> adminWorkDotColors = {
  'running': Color(0xFF108F25),
  'shell': Color(0xFF997711),
  'stale': Color(0xFFE83342),
};

/// One hue per top-level caller family; index 0 is darkest (the manager's direct calls), each deeper call level is lighter.
const List<List<Color>> adminThreadShades = [
  [Color(0xFF197739), Color(0xFF1D8640), Color(0xFF209547), Color(0xFF22A14D)],
  [Color(0xFF2867BE), Color(0xFF3074D3), Color(0xFF4582D8), Color(0xFF578EDB)],
  [Color(0xFF9338D5), Color(0xFF9F4ED9), Color(0xFFA961DD), Color(0xFFB270E1)],
  [Color(0xFFBA2889), Color(0xFFD12C9A), Color(0xFFD849A8), Color(0xFFDD5EB2)],
];

/// The thread colour for a caller [family] (never negative) at call [depth]; depth 1, a direct call, is the darkest, deeper is lighter (clamped at 4 levels).
Color adminThreadColor(int family, int depth) =>
    adminThreadShades[family % adminThreadShades.length][(depth - 1).clamp(
      0,
      3,
    )];

/// For each entry, its caller-family number: roots are numbered 0,1,2.. in order of first appearance; an entry belongs to the family of its root (found by following `parent` through ids; at most entries.length steps, guards loops).
List<int> adminWorkFamilies(List<AdminWorkEntry> entries) {
  final indexById = <String, int>{
    for (var i = 0; i < entries.length; i++)
      if (entries[i].id != null) entries[i].id!: i,
  };
  final rootToFamily = <int, int>{};
  return [
    for (var i = 0; i < entries.length; i++)
      rootToFamily.putIfAbsent(
        _rootOf(i, entries, indexById),
        () => rootToFamily.length,
      ),
  ];
}

int _rootOf(
  int start,
  List<AdminWorkEntry> entries,
  Map<String, int> indexById,
) {
  var cur = start;
  for (var n = 0; n < entries.length; n++) {
    final p = entries[cur].parent;
    final next = p == null ? null : indexById[p];
    if (next == null) break;
    cur = next;
  }
  return cur;
}

/// The `who` of the caller of [e], or null when it has no caller, the caller is not in [entries], or its name is empty.
String? adminCallerName(AdminWorkEntry e, List<AdminWorkEntry> entries) {
  final parentId = e.parent;
  if (parentId == null) return null;
  for (final entry in entries) {
    if (entry.id == parentId) return entry.who.isEmpty ? null : entry.who;
  }
  return null;
}
