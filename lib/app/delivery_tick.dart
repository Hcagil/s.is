import 'package:flutter/material.dart';

import '../features/chat/domain/delivery.dart';
import '../l10n/app_localizations.dart';
import 'theme.dart';

/// The delivery tick in a sender's bubble corner (option A of the mockup):
/// a clock while pending or offline, one tick when sent, two grey ticks when
/// delivered, two blue ticks when read. Soft (about 75%) at rest; a change
/// cross-fades over 0.3 s.
class DeliveryTick extends StatelessWidget {
  const DeliveryTick({
    super.key,
    required this.delivery,
    this.color,
    this.size = 14,
  });

  final Delivery delivery;

  /// The rest colour (clock, one tick, two grey ticks); defaults to the
  /// surrounding text colour.
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final read = delivery == Delivery.read;
    final icon = switch (delivery) {
      Delivery.pending => Icons.schedule,
      Delivery.sent => Icons.done,
      Delivery.delivered || Delivery.read => Icons.done_all,
    };
    final l10n = AppLocalizations.of(context);
    final label = switch (delivery) {
      Delivery.pending => l10n.deliverySending,
      Delivery.sent => l10n.deliverySent,
      Delivery.delivered => l10n.deliveryDelivered,
      Delivery.read => l10n.deliveryRead,
    };
    return Semantics(
      label: label,
      child: ExcludeSemantics(
        child: AnimatedOpacity(
          duration: SisTokens.tickFade,
          opacity: read ? SisTokens.tickReadOpacity : SisTokens.tickRestOpacity,
          child: AnimatedSwitcher(
            duration: SisTokens.tickFade,
            child: Icon(
              icon,
              key: ValueKey(delivery),
              size: size,
              color: read
                  ? SisTokens.tickReadColor
                  : color ?? DefaultTextStyle.of(context).style.color,
            ),
          ),
        ),
      ),
    );
  }
}
