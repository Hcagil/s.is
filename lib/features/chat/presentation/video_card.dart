import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../l10n/app_localizations.dart';
import '../../autodownload/application/auto_download_controller.dart';
import '../../autodownload/domain/auto_download_settings.dart';
import '../application/chat_controllers.dart';
import '../application/chat_drafts.dart';
import '../domain/file_attachment.dart';
import '../domain/message.dart';
import '../domain/video.dart';
import 'video_player_page.dart';

const _dark = DecoratedBox(
  decoration: BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF232046), Color(0xFF7B6BFF)],
    ),
  ),
);

/// A video message: a 238 x 134 picture with duration and size chips and a
/// centre badge (play, download ring, compressing, sending or waiting).
class VideoCard extends ConsumerWidget {
  /// [boxless] puts the time on the picture (no bubble box around it).
  const VideoCard({
    super.key,
    required this.message,
    required this.radius,
    required this.boxless,
    required this.time,
  });

  /// The video message.
  final Message message;

  /// Corner radius of the picture.
  final double radius;

  /// True when the bubble has no box and the time sits on the picture.
  final bool boxless;

  /// The time and tick widget.
  final Widget time;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = message.file;
    if (file == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final stored = ref.watch(
      storedFileProvider((id: message.id, name: file.name)),
    );
    final path = stored.value;
    final thumbStored = ref
        .watch(storedFileProvider((id: message.id, name: 'thumb.jpg')))
        .value;
    final downloadFraction = ref.watch(
      fileDownloadsProvider.select((s) => s[message.id]),
    );
    final progress = ref.watch(
      videoProgressProvider.select((s) => s[message.id]),
    );
    final autoOk =
        ref.watch(autoDownloadNowProvider(MediaKind.videos)).value ?? false;
    final needsDownload =
        stored is AsyncData<String?> &&
        path == null &&
        message.attachmentPath != null &&
        !message.sending;
    if (needsDownload && autoOk && downloadFraction == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(fileDownloadsProvider.notifier).auto(message);
      });
    }
    final downloading = downloadFraction != null;

    final localThumb = file.thumbPath ?? thumbStored;
    final Widget thumb;
    if (localThumb != null) {
      thumb = Image.file(
        File(localThumb),
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => _dark,
      );
    } else if (message.attachmentPath != null) {
      thumb = switch (ref.watch(
        attachmentBytesProvider('${message.attachmentPath}.t'),
      )) {
        AsyncData(:final value) => Image.memory(
          value,
          fit: BoxFit.cover,
          gaplessPlayback: true,
        ),
        _ => _dark,
      };
    } else {
      thumb = _dark;
    }

    Widget ring(double? v) => SizedBox(
      width: 26,
      height: 26,
      child: SisProgressRing(value: v, color: Colors.white),
    );
    const playIcon = Icon(
      Icons.play_arrow_rounded,
      color: Colors.white,
      size: 26,
    );
    final fraction = progress?.fraction ?? 0;
    final percent = (fraction * 100).round();
    final Widget overlay;
    if (message.sending) {
      final badge = switch (progress?.stage) {
        VideoStage.compressing => _Badge(
          ring(fraction == 0 ? null : fraction),
          label: l.videoCompressing(percent),
        ),
        VideoStage.sending => _Badge(
          ring(fraction == 0 ? null : fraction),
          label: l.videoSending(percent),
        ),
        VideoStage.waiting => _Badge(playIcon, label: l.videoWaitingNetwork),
        null => _Badge(playIcon, label: l.videoWaiting),
      };
      overlay = Stack(
        alignment: Alignment.center,
        children: [
          badge,
          if (progress?.stage == VideoStage.compressing)
            Positioned(
              top: 6,
              right: 6,
              child: Semantics(
                button: true,
                label: l.videoCancelSend,
                child: GestureDetector(
                  key: ValueKey('video-cancel-${message.id}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => ref
                      .read(sendQueueProvider.notifier)
                      .cancelVideo(message.conversationId, message.id),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: const BoxDecoration(
                      color: Color(0x73000000),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    } else if (downloading || needsDownload) {
      final v = downloadFraction ?? 0.75;
      overlay = Center(
        child: _Badge(
          key: ValueKey('video-ring-${message.id}'),
          Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: SisProgressRing(
                  value: v == 0 ? null : v,
                  color: Colors.white,
                ),
              ),
              const Icon(
                Icons.arrow_downward_rounded,
                size: 16,
                color: Colors.white,
              ),
            ],
          ),
          label: downloading ? '${(v * 100).round()}%' : null,
        ),
      );
    } else {
      overlay = Center(
        child: Container(
          key: ValueKey('video-play-${message.id}'),
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.92),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            size: 28,
            color: Color(0xFF222222),
          ),
        ),
      );
    }

    final picture = ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: 238,
        height: 134,
        child: Stack(
          fit: StackFit.expand,
          children: [
            thumb,
            Positioned(
              left: 8,
              top: 8,
              child: _Chip(durationLabel(file.durationMs ?? 0)),
            ),
            Positioned(
              left: 8,
              bottom: 8,
              child: _Chip(fileSizeLabel(file.size)),
            ),
            overlay,
          ],
        ),
      ),
    );

    final tappable = GestureDetector(
      key: ValueKey('video-${message.id}'),
      behavior: HitTestBehavior.opaque,
      onTap: message.sending
          ? null
          : () async {
              if (path != null) {
                await openVideoPlayer(context, path);
              } else if (!downloading && needsDownload) {
                final failure = await ref
                    .read(fileDownloadsProvider.notifier)
                    .start(message);
                if (failure != null && context.mounted) {
                  showSisNotice(context, failure.message, isError: true);
                }
              }
            },
      child: picture,
    );

    if (boxless) {
      return Stack(
        children: [
          tappable,
          Positioned(
            right: 8,
            bottom: 8,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: time,
              ),
            ),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        tappable,
        Align(alignment: Alignment.centerRight, child: time),
      ],
    );
  }
}

/// A dark 44 px circle holding [inner], with an optional small label below.
class _Badge extends StatelessWidget {
  const _Badge(this.inner, {super.key, this.label});

  final Widget inner;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: const BoxDecoration(
            color: Color(0x73000000),
            shape: BoxShape.circle,
          ),
          child: Center(child: inner),
        ),
        if (label != null) ...[
          const SizedBox(height: 6),
          Text(
            label!,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

/// A small dark label chip on the picture (duration, size).
class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
