import 'dart:io';

import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../domain/video.dart';

/// Opens the review page; returns the videos to send, or null when the
/// member went back (every picked video is then discarded by the caller).
Future<List<VideoSource>?> showVideoReview(
  BuildContext context,
  List<VideoSource> videos,
) => Navigator.of(context).push(
  MaterialPageRoute<List<VideoSource>>(
    builder: (_) => VideoReviewPage(videos: videos),
  ),
);

/// A grid of the picked videos; tap a tile to select or deselect it.
class VideoReviewPage extends StatefulWidget {
  /// Creates the review page for [videos] (all selected at first).
  const VideoReviewPage({required this.videos, super.key});

  /// The picked videos.
  final List<VideoSource> videos;

  @override
  State<VideoReviewPage> createState() => _VideoReviewPageState();
}

class _VideoReviewPageState extends State<VideoReviewPage> {
  late final Set<String> _selected = {for (final v in widget.videos) v.id};

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    return Scaffold(
      appBar: AppBar(title: Text(l.videoReviewTitle)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 4,
                  crossAxisSpacing: 4,
                ),
                itemCount: widget.videos.length,
                itemBuilder: (context, index) {
                  final v = widget.videos[index];
                  final on = _selected.contains(v.id);
                  return Semantics(
                    button: true,
                    selected: on,
                    label: l.videoSelectLabel,
                    child: GestureDetector(
                      key: ValueKey('video-tile-${v.id}'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => setState(() {
                        if (!_selected.add(v.id)) _selected.remove(v.id);
                      }),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.file(
                              File(v.thumbPath),
                              fit: BoxFit.cover,
                              gaplessPlayback: true,
                              errorBuilder: (_, _, _) =>
                                  const ColoredBox(color: Color(0xFF232046)),
                            ),
                            Positioned(
                              left: 6,
                              bottom: 6,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.55),
                                  borderRadius: BorderRadius.circular(7),
                                ),
                                child: Text(
                                  durationLabel(v.durationMs),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              right: 6,
                              top: 6,
                              child: Container(
                                width: 22,
                                height: 22,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: on ? brand : Colors.transparent,
                                  border: Border.all(
                                    color: Colors.white,
                                    width: 2,
                                  ),
                                ),
                                child: on
                                    ? const Icon(
                                        Icons.check_rounded,
                                        size: 16,
                                        color: Colors.white,
                                      )
                                    : null,
                              ),
                            ),
                            if (on)
                              IgnorePointer(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    border: Border.all(color: brand, width: 3),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  key: const ValueKey('video-send'),
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.of(context).pop([
                          for (final v in widget.videos)
                            if (_selected.contains(v.id)) v,
                        ]),
                  child: Text(l.videoSendCount(_selected.length)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
