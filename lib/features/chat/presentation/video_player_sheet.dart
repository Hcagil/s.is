import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../application/video_refused.dart';
import '../domain/message.dart';
import '../domain/video_embed.dart';

/// Builds the player view. The real WebView is set in main.dart because only
/// the data layer may use a WebView package.
final videoEmbedViewProvider = Provider<Widget Function(VideoEmbedViewSpec)>(
  (_) => throw UnimplementedError('override in main'),
);

/// Shows the player as a card rising from the bottom.
Future<void> showVideoPlayer(
  BuildContext context, {
  required Message message,
  required VideoEmbed embed,
  Uint8List? poster,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: SisBrand.of(context).surface,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    clipBehavior: Clip.antiAlias,
    builder: (_) =>
        VideoPlayerSheet(message: message, embed: embed, poster: poster),
  );
}

/// A bottom card that plays a video embed.
class VideoPlayerSheet extends ConsumerStatefulWidget {
  /// Creates a video player sheet.
  const VideoPlayerSheet({
    super.key,
    required this.message,
    required this.embed,
    this.poster,
  });

  /// The message carrying the video.
  final Message message;

  /// The embed to play.
  final VideoEmbed embed;

  /// The card picture, shown until the player has loaded.
  final Uint8List? poster;

  @override
  ConsumerState<VideoPlayerSheet> createState() => _VideoPlayerSheetState();
}

class _VideoPlayerSheetState extends ConsumerState<VideoPlayerSheet> {
  VideoRefusal? _refusal;
  bool _loaded = false;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final ios = Theme.of(context).platform == TargetPlatform.iOS;
    final open = l.videoOpenIn(widget.embed.site.name);

    return Column(
      key: const ValueKey('video-player'),
      mainAxisSize: MainAxisSize.min,
      children: [
        if (ios)
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: t.line,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        _playerArea(context),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 2),
          child: Text(
            widget.message.linkPreview?.title ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, color: t.muted),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
          child: Text(
            l.videoPlayerPrivacy(widget.embed.site.label),
            key: const ValueKey('video-player-privacy'),
            style: TextStyle(
              fontSize: 11,
              color: t.muted.withValues(alpha: 0.8),
            ),
          ),
        ),
        Container(
          height: 48,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: t.line)),
          ),
          child: Row(
            children: [
              TextButton(
                key: const ValueKey('video-player-close'),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(
                  ios ? l.videoPlayerDone : l.videoPlayerClose.toUpperCase(),
                ),
              ),
              const Spacer(),
              IconButton(
                key: const ValueKey('video-player-copy'),
                tooltip: l.videoPlayerCopy,
                icon: const Icon(Icons.link_rounded),
                onPressed: _copy,
              ),
              TextButton(
                key: const ValueKey('video-player-open'),
                onPressed: _open,
                child: Text(ios ? open : open.toUpperCase()),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _playerArea(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final size = MediaQuery.sizeOf(context);
    final width = size.width;
    final height = switch (widget.embed.site) {
      VideoSite.youtube => width * 9 / 16,
      VideoSite.tiktok ||
      VideoSite.instagram => math.min(size.height * 0.6, width * 1.6),
      VideoSite.x => math.min(size.height * 0.5, 420.0),
    };

    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ref.watch(videoEmbedViewProvider)(
            VideoEmbedViewSpec(
              embed: widget.embed,
              onLoaded: _onLoaded,
              onRefused: _onRefused,
              onExternal: _onExternal,
            ),
          ),
          IgnorePointer(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 200),
              opacity: (_loaded || _refusal != null) ? 0 : 1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  widget.poster == null
                      ? DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [t.brandDeep, t.surfaceHigh],
                            ),
                          ),
                        )
                      : Image.memory(
                          widget.poster!,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                  Center(
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white.withValues(alpha: 0.45),
                        size: 36,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_refusal != null)
            Container(
              key: const ValueKey('video-player-refused'),
              color: const Color(0xD10A081E),
              padding: const EdgeInsets.all(24),
              alignment: Alignment.center,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _reason(l, _refusal!),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l.videoRefusedMore,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const ValueKey('video-player-refused-open'),
                    onPressed: _open,
                    child: Text(l.videoOpenIn(widget.embed.site.name)),
                  ),
                ],
              ),
            ),
          Positioned(
            left: 10,
            top: 10,
            child: IgnorePointer(
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: (_loaded || _refusal != null) ? 0 : 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    child: Text(
                      widget.embed.site.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _reason(AppLocalizations l, VideoRefusal r) => switch (r) {
    VideoRefusal.isPrivate => l.videoRefusedPrivate,
    VideoRefusal.deleted => l.videoRefusedDeleted,
    VideoRefusal.region => l.videoRefusedRegion,
    VideoRefusal.login => l.videoRefusedLogin,
    VideoRefusal.other => l.videoRefusedOther,
  };

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.embed.link.toString()));
    if (!mounted) return;
    showSisNotice(context, AppLocalizations.of(context).videoPlayerCopied);
  }

  Future<void> _open() async {
    await ref.read(linkOpenerProvider).open(widget.embed.link);
    if (mounted) Navigator.of(context).pop();
  }

  void _onExternal(Uri uri) {
    if (mounted && _refusal == null) {
      setState(() => _refusal = VideoRefusal.other);
    }
  }

  void _onLoaded() {
    if (mounted && _refusal == null) setState(() => _loaded = true);
  }

  void _onRefused(VideoRefusal r) {
    if (!mounted || _refusal != null) return;
    ref.read(videoRefusedProvider.notifier).refuse(widget.message.id);
    setState(() => _refusal = r);
  }
}
