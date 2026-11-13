/// Session data for one desk session.
final class AdminSession {
  const AdminSession({
    required this.name,
    required this.contextK,
    required this.counts,
    required this.rows,
    required this.todo,
  });

  /// Builds an [AdminSession] from the exported fields; never throws.
  factory AdminSession.fromFields(Map<String, Object?> f) {
    final name = f['name']?.toString() ?? '';
    final contextK = f['ctx'] is num ? f['ctx'] as num : null;

    final countsRaw = f['counts'];
    final Map<String, int> counts;
    if (countsRaw is Map) {
      final rawMap = Map<String, Object?>.from(countsRaw);
      counts = {
        for (final entry in rawMap.entries)
          if (entry.value is int) entry.key.toString(): entry.value as int,
      };
    } else {
      counts = const {};
    }

    final rowsRaw = f['rows'];
    final List<({String state, String goal})> rows;
    if (rowsRaw is List) {
      rows = <({String state, String goal})>[
        for (final element in rowsRaw)
          if (element is Map) _parseRow(Map<String, Object?>.from(element)),
      ];
    } else {
      rows = const [];
    }

    final todoRaw = f['todo'];
    final List<String> todo;
    if (todoRaw is List) {
      todo = <String>[
        for (final element in todoRaw)
          if (element is Map)
            _parseTodoItem(Map<String, Object?>.from(element)),
      ];
    } else {
      todo = const [];
    }

    return AdminSession(
      name: name,
      contextK: contextK,
      counts: counts,
      rows: rows,
      todo: todo,
    );
  }

  /// The session name.
  final String name;

  /// The context size in thousands, or null.
  final num? contextK;

  /// Task counts by state.
  final Map<String, int> counts;

  /// Open rows with state and goal.
  final List<({String state, String goal})> rows;

  /// Open to-do lines.
  final List<String> todo;

  static ({String state, String goal}) _parseRow(Map<String, Object?> m) {
    final state = m['state']?.toString() ?? '';
    final goal = m['goal']?.toString() ?? '';
    return (state: state, goal: goal);
  }

  static String _parseTodoItem(Map<String, Object?> m) {
    final listVal = m['list'];
    final String listStr = listVal != null ? listVal.toString() : '';

    final openVal = m['open'];
    final String openStr;
    if (openVal is List) {
      openStr = openVal.map((e) => e.toString()).join(', ');
    } else {
      openStr = '';
    }

    return '$listStr: $openStr';
  }
}

/// Dashboard data: what works now and the sessions.
final class AdminDashboard {
  /// True when the computer status is missing or older than 5 minutes.
  final bool stale;

  const AdminDashboard({
    required this.working,
    required this.sessions,
    this.stale = false,
  });

  /// Builds an [AdminDashboard] from the exported fields; never throws.
  factory AdminDashboard.fromFields(Map<String, Object?> f) {
    final workingRaw = f['working'];
    final List<String> working;
    if (workingRaw is List) {
      working = <String>[
        for (final element in workingRaw) _parseWorkingElement(element),
      ];
    } else {
      working = const [];
    }

    final sessionsRaw = f['sessions'];
    final List<AdminSession> sessions;
    if (sessionsRaw is List) {
      sessions = <AdminSession>[
        for (final element in sessionsRaw)
          if (element is Map)
            AdminSession.fromFields(Map<String, Object?>.from(element)),
      ];
    } else {
      sessions = const [];
    }

    return AdminDashboard(
      working: working,
      sessions: sessions,
      stale: f['stale'] == true,
    );
  }

  /// What works now (sessions and workers).
  final List<String> working;

  /// The desk sessions.
  final List<AdminSession> sessions;

  static String _parseWorkingElement(Object? element) {
    if (element is Map) {
      final parts = <String>[];
      final name = (element['who'] ?? element['name'])?.toString() ?? '';
      final goal = (element['doing'] ?? element['goal'])?.toString() ?? '';
      if (name.isNotEmpty) parts.add(name);
      if (goal.isNotEmpty) parts.add(goal);
      return parts.join(': ');
    }
    return element.toString();
  }
}
