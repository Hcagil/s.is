import 'package:shared_preferences/shared_preferences.dart';

import '../domain/auto_download_settings.dart';

/// [AutoDownloadStore] over shared_preferences: per device, never synced.
final class SharedPrefsAutoDownloadStore implements AutoDownloadStore {
  const SharedPrefsAutoDownloadStore();

  @override
  Future<AutoDownloadSettings> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      var settings = const AutoDownloadSettings();
      for (final network in NetworkKind.values) {
        final key = 'sis.autodownload.${network.name}';
        final raw = prefs.getStringList(key);
        if (raw != null) {
          settings = settings.withKinds(
            network,
            {for (final name in raw) MediaKind.values.asNameMap()[name]}
                .whereType<MediaKind>()
                .toSet(),
          );
        }
      }
      return settings;
    } catch (_) {
      return const AutoDownloadSettings();
    }
  }

  @override
  Future<void> save(AutoDownloadSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    for (final network in NetworkKind.values) {
      final key = 'sis.autodownload.${network.name}';
      prefs.setStringList(key, [
        for (final k in settings.kindsFor(network)) k.name,
      ]);
    }
  }
}
