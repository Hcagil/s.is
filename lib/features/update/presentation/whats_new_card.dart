import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/update_controller.dart';
import '../domain/update_state.dart';
import '../domain/whats_new_note.dart';

/// True while an update is on offer, downloading or ready to install.
bool _updateWaiting(UpdateState? s) =>
    s is UpdateAvailableFlexible ||
    s is UpdateDownloading ||
    s is UpdateReadyToInstall;

/// One release note in the SIS chat, drawn as a card: a version heading and bullet
/// points, or the plain text when the note cannot be read that way. The newest
/// card is lit (brand border and glow) while an update is waiting; every other card is dimmed.
class WhatsNewCard extends ConsumerWidget {
  const WhatsNewCard({
    super.key,
    required this.body,
    required this.time,
    required this.isNewest,
  });
  final String body; // the message text
  final String time; // already formatted, shown small at the bottom
  final bool isNewest; // true for the newest note in the chat
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final note = parseWhatsNewNote(body);
    final accent =
        isNewest && _updateWaiting(ref.watch(updateControllerProvider).value);
    final t = SisBrand.of(context);
    return Opacity(
      opacity: accent ? 1 : 0.7,
      child: Container(
        key: ValueKey(accent ? 'whats-new-card-new' : 'whats-new-card-old'),
        margin: const EdgeInsets.fromLTRB(12, 5, 12, 5),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: t.surfaceHigh,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: accent ? t.brand : t.line),
          boxShadow: accent
              ? [BoxShadow(color: t.glow, spreadRadius: 2)]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (note.isStructured) ...[
              Text(
                AppLocalizations.of(context)
                    .whatsNewVersion(note.version!)
                    .toUpperCase(),
                style: TextStyle(
                  color: t.brand,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.7,
                ),
              ),
              const SizedBox(height: 8),
              for (final b in note.bullets)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '• ',
                        style: TextStyle(
                          color: t.text,
                          fontSize: 13.5,
                          height: 1.5,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          b,
                          style: TextStyle(
                            color: t.text,
                            fontSize: 13.5,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ] else
              Text(
                note.text,
                style: TextStyle(color: t.text, fontSize: 13.5, height: 1.5),
              ),
            const SizedBox(height: 8),
            Text(time, style: TextStyle(color: t.muted, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

/// "You're up to date": a small pill shown when no update is waiting.
class UpToDateMark extends ConsumerWidget {
  const UpToDateMark({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(updateControllerProvider).value is! UpdateIdle) {
      return const SizedBox.shrink();
    }
    final t = SisBrand.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Center(
        child: Container(
          key: const ValueKey('whats-new-up-to-date'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: t.brand.withAlpha(46),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            AppLocalizations.of(context).whatsNewUpToDate,
            style: TextStyle(
              color: t.brand,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
