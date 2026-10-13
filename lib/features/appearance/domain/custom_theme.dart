/// Which phone brightness a custom theme uses. automatic follows the phone.
enum CustomThemeMode { automatic, light, dark }

/// A theme the member made, kept on this phone only. Colours are ARGB ints
/// (0xFFRRGGBB).
final class CustomTheme {
  const CustomTheme({
    required this.id,
    required this.name,
    required this.mode,
    required this.accent,
    required this.mine,
    required this.theirs,
    this.background,
  });

  /// Unique on this phone.
  final String id;
  final String name;
  final CustomThemeMode mode;

  /// Buttons, links, highlights.
  final int accent;

  /// My message bubble.
  final int mine;

  /// Other people's bubble.
  final int theirs;

  /// Chat-area colour behind the messages; null: the mode's default.
  final int? background;

  CustomTheme copyWith({
    String? id,
    String? name,
    CustomThemeMode? mode,
    int? accent,
    int? mine,
    int? theirs,
    int? background,
  }) {
    return CustomTheme(
      id: id ?? this.id,
      name: name ?? this.name,
      mode: mode ?? this.mode,
      accent: accent ?? this.accent,
      mine: mine ?? this.mine,
      theirs: theirs ?? this.theirs,
      background: background ?? this.background,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'mode': mode.name,
    'accent': accent,
    'mine': mine,
    'theirs': theirs,
    'background': ?background,
  };

  /// Null for anything that is not a complete, valid theme. Never throws.
  static CustomTheme? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final mode = json['mode'];
    final accent = json['accent'];
    final mine = json['mine'];
    final theirs = json['theirs'];
    final background = json['background'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;
    if (mode is! String) return null;
    final modeValue = CustomThemeMode.values.asNameMap()[mode];
    if (modeValue == null) return null;
    if (accent is! int || mine is! int || theirs is! int) return null;
    return CustomTheme(
      id: id,
      name: name,
      mode: modeValue,
      accent: accent,
      mine: mine,
      theirs: theirs,
      background: background is int ? background : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CustomTheme &&
      other.id == id &&
      other.name == name &&
      other.mode == mode &&
      other.accent == accent &&
      other.mine == mine &&
      other.theirs == theirs &&
      other.background == background;

  @override
  int get hashCode =>
      Object.hash(id, name, mode, accent, mine, theirs, background);
}
