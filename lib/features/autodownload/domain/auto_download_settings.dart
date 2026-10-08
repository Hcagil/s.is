enum MediaKind { photos, audio, videos, documents }

enum NetworkKind { mobile, wifi, roaming }

enum AutoDownloadPreset { enable, wifiOnly, disabled }

/// Which kinds of media download by themselves on which kind of network. Stored on this phone only (see AutoDownloadStore).
final class AutoDownloadSettings {
  const AutoDownloadSettings({this.rules = _defaultRules});
  final Map<NetworkKind, Set<MediaKind>> rules;

  /// Defaults: mobile data = photos; Wi-Fi = all; roaming = nothing.
  static const Map<NetworkKind, Set<MediaKind>> _defaultRules = {
    NetworkKind.mobile: {MediaKind.photos},
    NetworkKind.wifi: {
      MediaKind.photos,
      MediaKind.audio,
      MediaKind.videos,
      MediaKind.documents,
    },
    NetworkKind.roaming: <MediaKind>{},
  };

  /// A network missing from [rules] counts as nothing downloading.
  Set<MediaKind> kindsFor(NetworkKind network) =>
      rules[network] ?? const <MediaKind>{};

  bool allows(NetworkKind network, MediaKind kind) =>
      kindsFor(network).contains(kind);

  /// A copy where [network] downloads exactly [kinds].
  AutoDownloadSettings withKinds(NetworkKind network, Set<MediaKind> kinds) =>
      AutoDownloadSettings(rules: {...rules, network: Set.unmodifiable(kinds)});

  /// The preset these rules equal exactly, or null when they are a custom mix (the defaults are a custom mix). enable = every kind on every network; wifiOnly = every kind on wifi, nothing on mobile and roaming; disabled = nothing anywhere.
  AutoDownloadPreset? get preset {
    final mobile = kindsFor(NetworkKind.mobile);
    final wifi = kindsFor(NetworkKind.wifi);
    final roaming = kindsFor(NetworkKind.roaming);

    // Set == is identity in Dart, so compare the members.
    bool isAll(Set<MediaKind> s) =>
        s.length == MediaKind.values.length && s.containsAll(MediaKind.values);
    if (mobile.isEmpty && wifi.isEmpty && roaming.isEmpty) {
      return AutoDownloadPreset.disabled;
    }
    if (mobile.isEmpty && isAll(wifi) && roaming.isEmpty) {
      return AutoDownloadPreset.wifiOnly;
    }
    if (isAll(mobile) && isAll(wifi) && isAll(roaming)) {
      return AutoDownloadPreset.enable;
    }
    return null;
  }

  static AutoDownloadSettings forPreset(AutoDownloadPreset preset) {
    switch (preset) {
      case AutoDownloadPreset.enable:
        return AutoDownloadSettings(
          rules: {
            NetworkKind.mobile: MediaKind.values.toSet(),
            NetworkKind.wifi: MediaKind.values.toSet(),
            NetworkKind.roaming: MediaKind.values.toSet(),
          },
        );
      case AutoDownloadPreset.wifiOnly:
        return AutoDownloadSettings(
          rules: {
            NetworkKind.mobile: <MediaKind>{},
            NetworkKind.wifi: MediaKind.values.toSet(),
            NetworkKind.roaming: <MediaKind>{},
          },
        );
      case AutoDownloadPreset.disabled:
        return AutoDownloadSettings(
          rules: {
            NetworkKind.mobile: <MediaKind>{},
            NetworkKind.wifi: <MediaKind>{},
            NetworkKind.roaming: <MediaKind>{},
          },
        );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! AutoDownloadSettings) return false;
    return _sameSets(
          other.kindsFor(NetworkKind.mobile),
          kindsFor(NetworkKind.mobile),
        ) &&
        _sameSets(
          other.kindsFor(NetworkKind.wifi),
          kindsFor(NetworkKind.wifi),
        ) &&
        _sameSets(
          other.kindsFor(NetworkKind.roaming),
          kindsFor(NetworkKind.roaming),
        );
  }

  @override
  int get hashCode {
    return Object.hashAll([
      Object.hashAll(
        kindsFor(NetworkKind.mobile).map((k) => k.index).toList()..sort(),
      ),
      Object.hashAll(
        kindsFor(NetworkKind.wifi).map((k) => k.index).toList()..sort(),
      ),
      Object.hashAll(
        kindsFor(NetworkKind.roaming).map((k) => k.index).toList()..sort(),
      ),
    ]);
  }

  static bool _sameSets(Set<MediaKind> a, Set<MediaKind> b) {
    if (a.length != b.length) return false;
    final aList = a.toList()..sort((x, y) => x.index.compareTo(y.index));
    final bList = b.toList()..sort((x, y) => x.index.compareTo(y.index));
    for (var i = 0; i < aList.length; i++) {
      if (aList[i] != bList[i]) return false;
    }
    return true;
  }
}

/// Where the settings are kept on this phone.
abstract interface class AutoDownloadStore {
  /// The saved settings; the defaults when nothing is saved or the data is unreadable. Never throws.
  Future<AutoDownloadSettings> load();
  Future<void> save(AutoDownloadSettings settings);
}

/// What kind of network the phone is on right now.
abstract interface class NetworkProbe {
  /// The current network kind, or null when the phone is offline. Never throws.
  Future<NetworkKind?> current();
}
