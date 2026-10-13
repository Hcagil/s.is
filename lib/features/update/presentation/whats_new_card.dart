import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
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
    final note = parseWhatsNewNote(
      body,
      lang: Localizations.localeOf(context).languageCode,
    );
    final installedName = ref.watch(installedVersionProvider).value?.name;
    final installed = note.version != null && note.version == installedName;
    final state = ref.watch(updateControllerProvider).value;
    // This card is a build newer than the installed one: the member can go and get it.
    final newer =
        isNewest &&
        note.version != null &&
        installedName != null &&
        isNewerVersion(note.version!, installedName);
    final accent = isNewest && (newer || _updateWaiting(state));
    final t = SisBrand.of(context);
    return Container(
      key: ValueKey(accent ? 'whats-new-card-new' : 'whats-new-card-old'),
      margin: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.surfaceHigh,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent ? t.brand : t.line),
        boxShadow: accent ? [BoxShadow(color: t.glow, spreadRadius: 2)] : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (note.isStructured)
                Text(
                  AppLocalizations.of(context)
                      .whatsNewVersion(note.version!)
                      .toUpperCase(),
                  style: TextStyle(
                    color: isNewest ? t.brand : t.muted,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.7,
                  ),
                ),
              const Spacer(),
              Text(time, style: TextStyle(color: t.muted, fontSize: 11)),
            ],
          ),
          const SizedBox(height: 8),
          if (note.isStructured) ...[
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
          if (installed) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_rounded, size: 14, color: _ok(context)),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    AppLocalizations.of(context).whatsNewInstalled,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _ok(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (isNewest &&
              (state is UpdateAvailableFlexible ||
                  (newer &&
                      state is! UpdateDownloading &&
                      state is! UpdateReadyToInstall)))
            _UpdateButton(
              label: AppLocalizations.of(context).updateNow,
              // Play offers a flexible update: take it here. Otherwise the store page.
              onPressed: state is UpdateAvailableFlexible
                  ? ref.read(updateControllerProvider.notifier).download
                  : ref.read(updateControllerProvider.notifier).openStore,
            ),
          if (isNewest && state is UpdateDownloading) ...[
            const SizedBox(height: 12),
            const SisProgressLine(),
            const SizedBox(height: 6),
            Text(
              AppLocalizations.of(context).updateDownloading,
              style: TextStyle(color: t.muted, fontSize: 12.5),
            ),
          ],
          if (isNewest && state is UpdateReadyToInstall)
            _UpdateButton(
              label: AppLocalizations.of(context).updateRestart,
              onPressed: ref.read(updateControllerProvider.notifier).install,
            ),
        ],
      ),
    );
  }
}

/// Design green for "installed" and "up to date" (mockup --ok).
Color _ok(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xFF5FD08A)
    : const Color(0xFF2E9A58);

/// Full-width 44 px brand button of an update card.
class _UpdateButton extends StatelessWidget {
  const _UpdateButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: SizedBox(
      width: double.infinity,
      height: 44,
      child: FilledButton(onPressed: onPressed, child: Text(label)),
    ),
  );
}

/// "You're up to date": a small pill shown when no update is waiting.
class UpToDateMark extends ConsumerWidget {
  const UpToDateMark({super.key, this.newestBody});

  /// Text of the newest note in the chat; when it names a build newer than the
  /// installed one the chip stays hidden.
  final String? newestBody;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(updateControllerProvider).value is! UpdateIdle) {
      return const SizedBox.shrink();
    }
    final newest = newestBody == null
        ? null
        : parseWhatsNewNote(newestBody!).version;
    final installedName = ref.watch(installedVersionProvider).value?.name;
    if (newest != null &&
        installedName != null &&
        isNewerVersion(newest, installedName)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Center(
        child: Container(
          key: const ValueKey('whats-new-up-to-date'),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: _ok(context).withAlpha(46),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            AppLocalizations.of(context).whatsNewUpToDate,
            style: TextStyle(
              color: _ok(context),
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }
}
