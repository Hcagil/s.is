/// A command definition for staff chat.
class StaffCommand {
  /// Creates a [StaffCommand] with the given [name] and [handler].
  const StaffCommand(
    this.name,
    this.handler, {
    this.helpEn = '',
    this.helpTr = '',
    this.arg = '',
    this.ui = '',
  });

  /// Creates a [StaffCommand] from a JSON map [j].
  factory StaffCommand.fromJson(Map<String, Object?> j) => StaffCommand(
    j['w'] as String? ?? '',
    j['h'] as String? ?? '',
    helpEn: j['e'] as String? ?? '',
    helpTr: j['t'] as String? ?? '',
    arg: j['g'] as String? ?? '',
    ui: j['u'] as String? ?? '',
  );

  /// The command word, for example the text typed after a slash.
  final String name;

  /// A legacy handler key; the server may send it empty and nothing depends on it.
  final String handler;

  /// English help text.
  final String helpEn;

  /// Turkish help text.
  final String helpTr;

  /// The kind of argument the command takes after the word, for example email;
  /// empty for none.
  final String arg;

  /// A neutral UI hint, for example total for a command whose answer is a
  /// total; empty for none.
  final String ui;

  /// Whether this command takes an email argument.
  bool get takesEmail => arg == 'email';

  /// Whether this command takes an account tag argument.
  bool get takesTag => arg == 'tag';

  /// Returns the help text in [lang], falling back to English.
  String help(String lang) =>
      lang == 'tr' && helpTr.isNotEmpty ? helpTr : helpEn;

  /// Converts this instance to a JSON map.
  Map<String, Object?> toJson() => {
    'w': name,
    'h': handler,
    'e': helpEn,
    't': helpTr,
    'g': arg,
    'u': ui,
  };
}

/// A staff chat as the server lists it: title and commands.
class StaffChat {
  /// Creates a [StaffChat].
  const StaffChat(
    this.key, {
    this.titleEn = '',
    this.titleTr = '',
    this.commands = const [],
  });

  /// Creates a [StaffChat] from a JSON map [j].
  factory StaffChat.fromJson(Map<String, Object?> j) => StaffChat(
    j['k'] as String? ?? '',
    titleEn: j['a'] as String? ?? '',
    titleTr: j['b'] as String? ?? '',
    commands: [
      for (final c in j['c'] as List<Object?>? ?? const [])
        if (c is Map<String, Object?>) StaffCommand.fromJson(c),
    ],
  );

  /// The neutral key of this chat.
  final String key;

  /// English title.
  final String titleEn;

  /// Turkish title.
  final String titleTr;

  /// The commands of this chat.
  final List<StaffCommand> commands;

  /// Returns the title in [lang], falling back to English.
  String title(String lang) =>
      lang == 'tr' && titleTr.isNotEmpty ? titleTr : titleEn;

  /// Converts this instance to a JSON map.
  Map<String, Object?> toJson() => {
    'k': key,
    'a': titleEn,
    'b': titleTr,
    'c': [for (final c in commands) c.toJson()],
  };
}

/// The staff chats and commands the server lets this member see.
class StaffRegistry {
  /// Creates a [StaffRegistry] with the given [chats].
  const StaffRegistry([this.chats = const {}]);

  /// Reads the rows of the staff_registry RPC (one row per command).
  factory StaffRegistry.fromRows(List<Map<String, Object?>> rows) {
    final titles = <String, List<String>>{};
    final commands = <String, List<StaffCommand>>{};
    for (final row in rows) {
      final key = row['chat_key'];
      if (key is! String) continue;
      titles[key] = [
        row['title_en'] as String? ?? '',
        row['title_tr'] as String? ?? '',
      ];
      final list = commands.putIfAbsent(key, () => []);
      final word = row['word'];
      if (word is! String) continue;
      list.add(
        StaffCommand(
          word,
          row['handler'] as String? ?? '',
          helpEn: row['help_en'] as String? ?? '',
          helpTr: row['help_tr'] as String? ?? '',
          arg: row['arg'] as String? ?? '',
          ui: row['ui'] as String? ?? '',
        ),
      );
    }
    return StaffRegistry({
      for (final e in titles.entries)
        e.key: StaffChat(
          e.key,
          titleEn: e.value[0],
          titleTr: e.value[1],
          commands: commands[e.key] ?? const [],
        ),
    });
  }

  /// Reads a stored registry; anything malformed gives [empty].
  factory StaffRegistry.fromJson(Map<String, Object?> j) {
    try {
      return StaffRegistry({
        for (final c in j['chats'] as List<Object?>? ?? const [])
          if (c is Map<String, Object?>)
            StaffChat.fromJson(c).key: StaffChat.fromJson(c),
      });
    } on TypeError {
      return empty;
    }
  }

  /// No chats: what a non-member (or a not yet loaded registry) sees.
  static const empty = StaffRegistry();

  /// Staff chats by their neutral key.
  final Map<String, StaffChat> chats;

  /// The commands of the chat [key]; empty when unknown.
  List<StaffCommand> commandsFor(String? key) =>
      key == null ? const [] : chats[key]?.commands ?? const [];

  /// The chat title in [lang], or null when the server gave none.
  String? titleFor(String? key, String lang) {
    final t = key == null ? '' : chats[key]?.title(lang) ?? '';
    return t.isEmpty ? null : t;
  }

  /// The first command word of chat [key] with the UI hint [ui], or null.
  String? wordForUi(String? key, String ui) {
    for (final c in commandsFor(key)) {
      if (c.ui == ui) return c.name;
    }
    return null;
  }

  /// Converts this instance to a JSON map.
  Map<String, Object?> toJson() => {
    'chats': [for (final c in chats.values) c.toJson()],
  };
}

/// Returns commands from [all] whose name starts with [typed]; empty unless
/// [typed] starts with '/' and has no space or newline yet.
List<StaffCommand> matchCommands(List<StaffCommand> all, String typed) {
  final t = typed.trimLeft();
  if (!t.startsWith('/') || t.contains(' ') || t.contains('\n')) {
    return const [];
  }
  return all.where((c) => c.name.startsWith(t.toLowerCase())).toList();
}
