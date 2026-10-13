import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/geo.dart';
import '../domain/shared_location.dart';
import 'map_providers.dart';

/// Pick a place: move the map under a pin, the address follows, then send.
/// Pops the [SharedLocation] to send.
class LocationPickPage extends ConsumerStatefulWidget {
  /// Creates the page; [autofocusSearch] opens the keyboard on the search box.
  const LocationPickPage({super.key, this.autofocusSearch = false});

  /// Whether the search field takes focus at once.
  final bool autofocusSearch;

  @override
  ConsumerState<LocationPickPage> createState() => _LocationPickPageState();
}

class _LocationPickPageState extends ConsumerState<LocationPickPage> {
  // A neutral starting view when the phone's position is unknown.
  static const _fallback = GeoPoint(41.0082, 28.9784);

  final _query = TextEditingController();
  bool _lifted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = ref.read(locationPickerProvider);
      if (s.center == null) {
        ref
            .read(locationPickerProvider.notifier)
            .moveTo(s.me?.point ?? _fallback);
      }
    });
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final state = ref.watch(locationPickerProvider);
    final center = state.center ?? state.me?.point ?? _fallback;
    final address = state.address;
    final canSearch = ref.watch(placeSearchProvider).canSearch;
    return Scaffold(
      appBar: AppBar(title: Text(l.locationPickTitle)),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: ref.watch(mapViewProvider)(
                    MapViewSpec(
                      target: center,
                      me: state.me?.point,
                      onMoveStart: () => setState(() => _lifted = true),
                      onCenterChanged: (c) {
                        setState(() => _lifted = false);
                        ref.read(locationPickerProvider.notifier).moveTo(c);
                      },
                    ),
                  ),
                ),
                IgnorePointer(
                  child: Center(
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: 16,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Transform.translate(
                          offset: Offset(0, _lifted ? -34 : -22),
                          child: Icon(
                            Icons.location_on,
                            size: 44,
                            color: t.danger,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (canSearch)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 10,
                    child: Material(
                      color: t.surface,
                      borderRadius: BorderRadius.circular(20),
                      elevation: 2,
                      child: TextField(
                        autofocus: widget.autofocusSearch,
                        controller: _query,
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.search),
                          hintText: l.locationSearchHint,
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                        onChanged: (text) {
                          setState(() {});
                          ref
                              .read(locationPickerProvider.notifier)
                              .search(text);
                        },
                      ),
                    ),
                  ),
                if (canSearch && state.suggestions.isNotEmpty)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 54,
                    child: Material(
                      color: t.surfaceHigh,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 2,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 260),
                        child: ListView(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          children: [
                            for (final s in state.suggestions)
                              InkWell(
                                key: ValueKey('location-suggestion-${s.id}'),
                                onTap: () {
                                  _query.clear();
                                  FocusScope.of(context).unfocus();
                                  ref
                                      .read(locationPickerProvider.notifier)
                                      .choose(s);
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        s.name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      if (s.address.isNotEmpty)
                                        Text(
                                          s.address,
                                          style: TextStyle(
                                            color: t.muted,
                                            fontSize: 12,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  )
                else if (canSearch &&
                    !state.searching &&
                    _query.text.trim().isNotEmpty)
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 54,
                    child: Material(
                      color: t.surfaceHigh,
                      borderRadius: BorderRadius.circular(12),
                      elevation: 2,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          l.locationNoResults,
                          style: TextStyle(color: t.muted),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: t.surfaceHigh,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: t.line),
            ),
            child: Row(
              children: [
                const Icon(Icons.location_on_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        address?.name ??
                            coordinatesText(center.lat, center.lng),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (address != null && address.address.isNotEmpty)
                        Text(
                          address.address,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: t.muted, fontSize: 12),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton(
                key: const ValueKey('location-send'),
                onPressed: () => Navigator.of(context)
                    .pop(ref.read(locationPickerProvider.notifier).pinned()),
                child: Text(l.locationSendThis),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
