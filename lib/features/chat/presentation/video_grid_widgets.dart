import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/video.dart';
import '../domain/video_gallery.dart';

/// A video in the grid, with its thumbnail and duration.
class VideoGridTile extends ConsumerStatefulWidget {
  /// Creates a video tile.
  const VideoGridTile({
    super.key,
    required this.video,
    required this.selected,
    required this.onTap,
  });

  /// The video to show.
  final GalleryVideo video;

  /// True when selected (tick shown).
  final bool selected;

  /// Called when tapped.
  final VoidCallback onTap;

  @override
  ConsumerState<VideoGridTile> createState() => _VideoGridTileState();
}

class _VideoGridTileState extends ConsumerState<VideoGridTile> {
  // Asked once: rebuilding the grid must not refetch every thumbnail.
  late final Future<Uint8List?> _bytes = ref
      .read(videoGalleryProvider)
      .thumbnail(widget.video);

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context).brand;
    return Semantics(
      button: true,
      selected: widget.selected,
      label: AppLocalizations.of(context).videoSelectLabel,
      child: InkWell(
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<Uint8List?>(
              future: _bytes,
              builder: (context, snapshot) => switch (snapshot.data) {
                final Uint8List data => Image.memory(
                  data,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
                // Not read yet, or unreadable: a quiet tile, but still tappable
                // (a limited-access video can be slow, and a tap must never be
                // lost).
                null => ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHigh,
                ),
              },
            ),
            Positioned(
              right: 5,
              bottom: 5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  durationLabel(widget.video.durationMs),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            if (widget.selected)
              IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: brand, width: 3),
                  ),
                ),
              ),
            if (widget.selected)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  key: ValueKey('video-grid-tick-${widget.video.id}'),
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: brand,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// SIS's own screen for asking video access: shown instead of the grid
/// when access is denied, or opens the app's settings page when a previous
/// ask was already refused (the system will not prompt again).
class VideoAccessRequest extends StatelessWidget {
  /// Creates a video access request.
  const VideoAccessRequest({
    super.key,
    required this.permanentlyDenied,
    required this.onAllow,
    required this.onOpenSettings,
    required this.onPhonePicker,
    required this.onNotNow,
  });

  /// True when the system will not prompt again.
  final bool permanentlyDenied;

  /// Called when the member allows access.
  final VoidCallback onAllow;

  /// Called when the member opens settings to allow access.
  final VoidCallback onOpenSettings;

  /// Called when the member chooses the phone's own video picker instead.
  final VoidCallback onPhonePicker;

  /// Called when the member does not want to allow access now.
  final VoidCallback onNotNow;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    // A short phone (360x640 dp and smaller) cannot fit the icon, both
    // lines of text and both buttons at once; scroll rather than clip --
    // the buttons must always be reachable, never cut off.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: t.surfaceHigh,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Icon(
                      Icons.video_library_rounded,
                      size: 48,
                      color: t.brand,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    AppLocalizations.of(context).videoAccessTitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    AppLocalizations.of(context).videoAccessBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.muted),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const ValueKey('video-allow'),
                      onPressed: permanentlyDenied ? onOpenSettings : onAllow,
                      child: Text(
                        permanentlyDenied
                            ? AppLocalizations.of(context).attachOpenSettings
                            : AppLocalizations.of(context).videoAllow,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const ValueKey('video-phone-picker'),
                    onPressed: onPhonePicker,
                    icon: const Icon(Icons.video_library_outlined, size: 18),
                    label: Text(
                      AppLocalizations.of(context).videoUsePhonePicker,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const ValueKey('video-not-now'),
                    onPressed: onNotNow,
                    child: Text(AppLocalizations.of(context).attachNotNow),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
