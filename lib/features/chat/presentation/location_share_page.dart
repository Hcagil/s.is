import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/geo.dart';
import '../domain/shared_location.dart';
import 'location_pick_page.dart';
import 'map_providers.dart';

/// Opens the Share location page; the result is the place to send, or null
/// when the member backed out.
Future<SharedLocation?> showLocationShare(BuildContext context) =>
    Navigator.of(context).push<SharedLocation>(
      MaterialPageRoute(builder: (_) => const LocationSharePage()),
    );

/// Share where you are with one tap, or pick a place on the map.
class LocationSharePage extends ConsumerStatefulWidget {
  /// Creates the page.
  const LocationSharePage({super.key});

  @override
  ConsumerState<LocationSharePage> createState() => _LocationSharePageState();
}

class _LocationSharePageState extends ConsumerState<LocationSharePage> {
  // A neutral starting view when the phone's position is unknown.
  static const _fallback = GeoPoint(41.0082, 28.9784);

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(locationPickerProvider.notifier).start();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final state = ref.watch(locationPickerProvider);
    final me = state.me;
    return Scaffold(
      appBar: AppBar(title: Text(l.locationShareTitle)),
      body: Column(
        children: [
          SizedBox(
            height: 290,
            child: Stack(
              children: [
                ref.watch(mapViewProvider)(
                  MapViewSpec(
                    target: me?.point ?? _fallback,
                    me: me?.point,
                    interactive: false,
                  ),
                ),
                if (ref.watch(placeSearchProvider).canSearch)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 10,
                    height: 40,
                    child: Material(
                      color: t.surface,
                      borderRadius: BorderRadius.circular(20),
                      elevation: 2,
                      child: InkWell(
                        key: const ValueKey('location-search-pill'),
                        onTap: () => _pick(autofocus: true),
                        borderRadius: BorderRadius.circular(20),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              const Icon(Icons.search),
                              const SizedBox(width: 8),
                              Text(
                                l.locationSearchHint,
                                style: TextStyle(color: t.muted),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Card(
            margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            color: t.surfaceHigh,
            shape: RoundedRectangleBorder(
              side: BorderSide(color: t.line),
              borderRadius: BorderRadius.circular(18),
            ),
            clipBehavior: Clip.hardEdge,
            child: Column(
              children: [
                ListTile(
                  key: const ValueKey('location-share-current'),
                  leading: const Icon(Icons.my_location),
                  title: Text(
                    l.locationShareCurrent,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    me != null
                        ? l.locationShareAccuracy(me.accuracyMeters.round())
                        : l.locationShareCurrentSub,
                    style: TextStyle(fontSize: 12, color: t.muted),
                  ),
                  onTap: _shareCurrent,
                ),
                ListTile(
                  key: const ValueKey('location-pick'),
                  leading: const Icon(Icons.map_outlined),
                  title: Text(l.locationPickTitle),
                  subtitle: Text(l.locationPickSub),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _pick(autofocus: false),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              switch (state.access) {
                LocationAccess.denied ||
                LocationAccess.deniedForever => l.locationDenied,
                LocationAccess.unavailable => l.locationUnavailable,
                _ => l.locationPermNote,
              },
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: t.muted),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _shareCurrent() async {
    if (_busy) return;
    setState(() => _busy = true);
    final r = await ref.read(locationPickerProvider.notifier).shareCurrent();
    if (!mounted) return;
    final l = AppLocalizations.of(context);
    switch (r) {
      case Ok(:final value):
        Navigator.of(context).pop(value);
      case Err(:final failure):
        showSisNotice(
          context,
          failure is LocationDeniedFailure
              ? l.locationDenied
              : failure is LocationUnavailableFailure
              ? l.locationUnavailable
              : failure.message,
          isError: true,
        );
        setState(() => _busy = false);
    }
  }

  Future<void> _pick({required bool autofocus}) async {
    final r = await Navigator.of(context).push<SharedLocation>(
      MaterialPageRoute(
        builder: (_) => LocationPickPage(autofocusSearch: autofocus),
      ),
    );
    if (r != null && mounted) Navigator.of(context).pop(r);
  }
}
