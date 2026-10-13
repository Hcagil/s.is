import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/geo.dart';
import '../domain/message.dart';
import '../domain/shared_location.dart';
import 'map_providers.dart';
import 'open_in_maps_card.dart';

/// A location message inside a chat bubble: a small map with a pin, the place
/// name and address, and the time and tick. Tapping asks to open the maps app.
class LocationCard extends ConsumerWidget {
  /// [time] is the time and tick widget, already coloured by the caller.
  const LocationCard({super.key, required this.message, required this.time});

  /// The location message.
  final Message message;

  /// The time and tick widget.
  final Widget time;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loc = message.location;
    if (loc == null) return const SizedBox.shrink();
    final brand = SisBrand.of(context);
    final point = GeoPoint(loc.lat, loc.lng);
    return GestureDetector(
      key: ValueKey('location-${message.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(context, ref, loc),
      child: Container(
        width: 238,
        decoration: BoxDecoration(
          color: brand.surfaceHigh,
          borderRadius: BorderRadius.circular(brand.bubbleRadius),
          border: Border.all(color: brand.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 84,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ref.watch(mapPreviewProvider)(point),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 28),
                      child: Icon(
                        Icons.location_on,
                        size: 32,
                        color: brand.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    loc.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: brand.text,
                    ),
                  ),
                  if (loc.address.isNotEmpty)
                    Text(
                      loc.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: brand.muted),
                    ),
                  Align(alignment: Alignment.centerRight, child: time),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    SharedLocation loc,
  ) async {
    final place = loc.address.isEmpty
        ? loc.name
        : '${loc.name}, ${loc.address}';
    final go = await confirmOpenInMaps(context, place: place);
    if (go != true || !context.mounted) return;
    final ok = await ref
        .read(mapsOpenerProvider)
        .open(GeoPoint(loc.lat, loc.lng), loc.name);
    if (!ok && context.mounted) {
      showSisNotice(
        context,
        AppLocalizations.of(context).locationOpenFailed,
        isError: true,
      );
    }
  }
}
