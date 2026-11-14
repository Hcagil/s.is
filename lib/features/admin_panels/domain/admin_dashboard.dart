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

/// One row of "running now": a session, agent or worker, with its caller.
final class AdminWorkEntry {
  const AdminWorkEntry({
    required this.title,
    this.who = '',
    this.id,
    this.parent,
    this.state = '',
    this.depth = 0,
  });

  /// Builds an entry from one exported element; never throws.
  factory AdminWorkEntry.fromElement(Object? element) {
    if (element is! Map) return AdminWorkEntry(title: element.toString());
    final who = (element['who'] ?? element['name'])?.toString() ?? '';
    final goal = (element['doing'] ?? element['goal'])?.toString() ?? '';
    final rawState = element['state']?.toString() ?? '';
    final state = const {'running', 'shell', 'stale'}.contains(rawState)
        ? rawState
        : (element['stale'] == true ? 'stale' : '');
    final id = element['id']?.toString();
    final parent = element['parent']?.toString();
    return AdminWorkEntry(
      title: [if (who.isNotEmpty) who, if (goal.isNotEmpty) goal].join(': '),
      who: who,
      id: (id == null || id.isEmpty) ? null : id,
      parent: (parent == null || parent.isEmpty) ? null : parent,
      state: state,
      depth: element['depth'] is num ? (element['depth'] as num).toInt() : 0,
    );
  }

  /// The text shown: "who: doing".
  final String title;

  /// The name of this session or agent (empty when unknown).
  final String who;

  /// Its id, or null (old computer).
  final String? id;

  /// The id of the caller, or null (top level, or old computer).
  final String? parent;

  /// 'running', 'shell', 'stale', or '' when unknown.
  final String state;

  /// 0 for a top-level session, 1 for what it called, and so on.
  final int depth;
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
    final List<AdminWorkEntry> working;
    if (workingRaw is List) {
      working = <AdminWorkEntry>[
        for (final element in workingRaw) AdminWorkEntry.fromElement(element),
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
  final List<AdminWorkEntry> working;

  /// The desk sessions.
  final List<AdminSession> sessions;
}
