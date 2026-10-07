import 'appearance_settings.dart';

enum WallpaperKind { none, colour, gradient, picture }

/// The chat background, one for the whole app, kept on this phone only.
/// Colours are ARGB ints. colour: [colours] has 1 entry; gradient: 2 entries,
/// top then bottom; picture: [picturePath] is a file in the app's own folder.
/// [dim] 0..0.8 and [blur] 0..12 apply to a picture only.
final class Wallpaper {
  const Wallpaper({
    this.kind = WallpaperKind.none,
    this.colours = const [],
    this.picturePath,
    this.dim = 0.3,
    this.blur = 0,
  });

  static const none = Wallpaper();

  final WallpaperKind kind;
  final List<int> colours;
  final String? picturePath;
  final double dim;
  final double blur;

  Wallpaper copyWith({
    WallpaperKind? kind,
    List<int>? colours,
    String? picturePath,
    double? dim,
    double? blur,
  }) {
    return Wallpaper(
      kind: kind ?? this.kind,
      colours: colours ?? this.colours,
      picturePath: picturePath ?? this.picturePath,
      dim: dim ?? this.dim,
      blur: blur ?? this.blur,
    );
  }

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'colours': colours,
    'picturePath': ?picturePath,
    'dim': dim,
    'blur': blur,
  };

  /// [Wallpaper.none] for anything invalid. Never throws.
  static Wallpaper tryFromJson(Object? json) {
    if (json is! Map) return none;
    final kind = WallpaperKind.values.asNameMap()[json['kind']];
    if (kind == null) return none;
    final colours =
        (json['colours'] as List?)?.whereType<int>().toList() ?? <int>[];
    final path = json['picturePath'];
    final dim = json['dim'];
    final blur = json['blur'];
    final ok = switch (kind) {
      WallpaperKind.none => true,
      WallpaperKind.colour => colours.length == 1,
      WallpaperKind.gradient => colours.length == 2,
      WallpaperKind.picture => path is String && path.isNotEmpty,
    };
    if (!ok) return none;
    return Wallpaper(
      kind: kind,
      colours: colours,
      picturePath: path is String ? path : null,
      dim: dim is num ? dim.toDouble().clamp(0.0, 0.8) : 0.3,
      blur: blur is num ? blur.toDouble().clamp(0.0, 12.0) : 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Wallpaper &&
      other.kind == kind &&
      _same(other.colours, colours) &&
      other.picturePath == picturePath &&
      other.dim == dim &&
      other.blur == blur;

  @override
  int get hashCode =>
      Object.hash(kind, Object.hashAll(colours), picturePath, dim, blur);
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The wallpaper a built-in theme brings in dark mode (top, bottom), from the
/// approved design. Violet has none.
Wallpaper builtInWallpaper(AppThemeId id) {
  Wallpaper g(int top, int bottom) =>
      Wallpaper(kind: WallpaperKind.gradient, colours: [top, bottom]);
  switch (id) {
    case AppThemeId.violet:
      return Wallpaper.none;
    case AppThemeId.ocean:
      return g(0xFF0B2A45, 0xFF0A1626);
    case AppThemeId.forest:
      return g(0xFF0F2E22, 0xFF0A1A14);
    case AppThemeId.sunset:
      return g(0xFF3A1630, 0xFF1C0C1E);
    case AppThemeId.graphite:
      return g(0xFF25282E, 0xFF15171B);
    case AppThemeId.rose:
      return g(0xFF38142A, 0xFF1A0A14);
  }
}
