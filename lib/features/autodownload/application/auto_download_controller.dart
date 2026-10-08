import 'dart:developer';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/auto_download_settings.dart';

/// Where the settings are saved on this phone (shared_preferences in data/).
final autoDownloadStoreProvider = Provider<AutoDownloadStore>(
  (_) => throw UnimplementedError('override in main'),
);

/// The settings read before runApp, so the first frame is already right.
final initialAutoDownloadProvider = Provider<AutoDownloadSettings>(
  (_) => const AutoDownloadSettings(),
);

/// Tells which kind of network the phone is on (connectivity_plus in data/).
final networkProbeProvider = Provider<NetworkProbe>(
  (_) => throw UnimplementedError('override in main'),
);

final autoDownloadProvider =
    NotifierProvider<AutoDownloadController, AutoDownloadSettings>(
      AutoDownloadController.new,
    );

/// Whether media of [kind] downloads by itself right now, on the network the phone is on (false when offline).
final autoDownloadNowProvider = FutureProvider.autoDispose.family<bool, MediaKind>(
  (ref, kind) async {
    final settings = ref.watch(autoDownloadProvider);
    final network = await ref.read(networkProbeProvider).current();
    return network != null && settings.allows(network, kind);
  },
);

/// The member's auto-download choices. Each change shows at once and is then
/// saved; a failed save never throws or reverts the screen.
class AutoDownloadController extends Notifier<AutoDownloadSettings> {
  @override
  AutoDownloadSettings build() => ref.read(initialAutoDownloadProvider);

  /// Sets the preset (enable, wifiOnly, disabled).
  Future<void> setPreset(AutoDownloadPreset preset) =>
      _update(AutoDownloadSettings.forPreset(preset));

  /// Sets which kinds of media download on [network].
  Future<void> setKinds(NetworkKind network, Set<MediaKind> kinds) =>
      _update(state.withKinds(network, kinds));

  Future<void> _update(AutoDownloadSettings next) async {
    state = next;
    try {
      await ref.read(autoDownloadStoreProvider).save(next);
    } catch (e) {
      log('Saving auto-download failed: ${e.runtimeType}', name: 'sis.autodownload');
    }
  }
}
