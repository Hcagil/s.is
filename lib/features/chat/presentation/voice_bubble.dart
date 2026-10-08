import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../l10n/app_localizations.dart';
import '../../autodownload/application/auto_download_controller.dart';
import '../../autodownload/domain/auto_download_settings.dart';
import '../application/chat_controllers.dart';
import '../domain/message.dart';
import '../domain/voice.dart';

/// A voice message bubble.
class VoiceBubble extends ConsumerStatefulWidget {
  const VoiceBubble({
    super.key,
    required this.message,
    required this.mine,
    required this.ink,
    required this.accent,
    required this.time,
  });

  final Message message;
  final bool mine;
  final Color ink;
  final Color accent;
  final Widget time;

  @override
  ConsumerState<VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends ConsumerState<VoiceBubble> {
  bool _showText = false;

  @override
  Widget build(BuildContext context) {
    final file = widget.message.file;
    if (file == null) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final stored = ref.watch(
      storedFileProvider((id: widget.message.id, name: file.name)),
    );
    final progress = ref.watch(
      fileDownloadsProvider.select((s) => s[widget.message.id]),
    );
    final autoOk =
        ref.watch(autoDownloadNowProvider(MediaKind.audio)).value ?? false;
    final path = stored.value;
    final needsDownload =
        stored is AsyncData<String?> &&
        path == null &&
        widget.message.attachmentPath != null &&
        !widget.message.sending;

    if (needsDownload && autoOk && progress == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(fileDownloadsProvider.notifier).auto(widget.message);
      });
    }

    final downloading = progress != null;
    final state = ref.watch(voicePlayerProvider);
    final isThis = state.messageId == widget.message.id;
    final playing = isThis && state.playing;
    final position = state.position;
    final duration = state.duration;
    final speed = state.speed;
    final played = state.played;

    final ring = downloading || needsDownload;
    final onTap = widget.message.sending && path == null
        ? null
        : () async {
            if (downloading || needsDownload) {
              final failure = await ref
                  .read(fileDownloadsProvider.notifier)
                  .start(widget.message);
              if (failure != null && context.mounted) {
                showSisNotice(context, failure.message, isError: true);
              }
            } else {
              final r = await ref
                  .read(voicePlayerProvider.notifier)
                  .toggle(widget.message);
              if (context.mounted) {
                if (r.download != null) {
                  showSisNotice(context, r.download!.message, isError: true);
                } else if (r.cannotPlay) {
                  showSisNotice(context, l.voiceCannotPlay, isError: true);
                }
              }
            }
          };

    final bars = decodeWaveform(file.waveform);
    final barList = bars.isEmpty
        ? List<double>.filled(28, 0.35)
        : bars.toList();

    final fraction = isThis && duration.inMilliseconds > 0
        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    final clock = file.durationMs ?? 0;
    final timeText = isThis && (playing || position > Duration.zero)
        ? '${voiceClock(position.inMilliseconds)} / ${voiceClock(clock)}'
        : voiceClock(clock);

    final unplayed =
        !widget.mine &&
        !played.contains(widget.message.id) &&
        !widget.message.sending;

    final hasText = (file.transcript ?? '').isNotEmpty;

    return SizedBox(
      key: ValueKey('voice-${widget.message.id}'),
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                key: ValueKey(
                  ring
                      ? 'voice-ring-${widget.message.id}'
                      : 'voice-play-${widget.message.id}',
                ),
                width: 44,
                height: 44,
                child: GestureDetector(
                  onTap: onTap,
                  child: ring
                      ? Stack(
                          alignment: Alignment.center,
                          children: [
                            SizedBox.expand(
                              child: SisProgressRing(
                                value: downloading
                                    ? (progress == 0 ? null : progress)
                                    : 0.75,
                                color: widget.accent,
                              ),
                            ),
                            Icon(
                              Icons.arrow_downward_rounded,
                              size: 20,
                              color: widget.accent,
                            ),
                          ],
                        )
                      : Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: widget.accent.withValues(alpha: 0.25),
                          ),
                          child: Icon(
                            playing
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: widget.accent,
                            size: 28,
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 28,
                      key: ValueKey('voice-wave-${widget.message.id}'),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return CustomPaint(
                            size: Size(constraints.maxWidth, 28),
                            painter: _WavePainter(
                              bars: barList,
                              fraction: fraction,
                              ink: widget.ink,
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            timeText,
                            style: TextStyle(
                              fontSize: 12,
                              color: widget.ink.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                        if (playing)
                          GestureDetector(
                            key: ValueKey('voice-speed-${widget.message.id}'),
                            onTap: () async {
                              await ref
                                  .read(voicePlayerProvider.notifier)
                                  .cycleSpeed();
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: widget.ink.withValues(alpha: 0.4),
                                ),
                              ),
                              child: Text(
                                voiceSpeedLabel(speed),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: widget.accent,
                                ),
                              ),
                            ),
                          ),
                        if (unplayed) ...[
                          const SizedBox(width: 6),
                          Container(
                            key: ValueKey('voice-dot-${widget.message.id}'),
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: widget.accent,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (hasText) ...[
            const SizedBox(height: 6),
            GestureDetector(
              key: ValueKey('voice-text-toggle-${widget.message.id}'),
              onTap: () => setState(() => _showText = !_showText),
              child: Text(
                _showText ? l.voiceHideText : l.voiceShowText,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: widget.accent,
                ),
              ),
            ),
            if (_showText)
              Container(
                key: ValueKey('voice-transcript-${widget.message.id}'),
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.only(top: 6),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: widget.ink.withValues(alpha: 0.2)),
                  ),
                ),
                child: Text(
                  file.transcript!,
                  style: TextStyle(fontSize: 13, color: widget.ink),
                ),
              ),
          ],
          Align(alignment: Alignment.centerRight, child: widget.time),
        ],
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  const _WavePainter({
    required this.bars,
    required this.fraction,
    required this.ink,
  });

  final List<double> bars;
  final double fraction;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final step = size.width / bars.length;
    final barWidth = step * 0.6;
    for (var i = 0; i < bars.length; i++) {
      final h = bars[i];
      final barHeight = math.max(4.0, h * 28);
      final x = i * step + (step - barWidth) / 2;
      final rect = Rect.fromLTWH(x, (28 - barHeight) / 2, barWidth, barHeight);
      final paint = Paint()
        ..color = i < fraction * bars.length
            ? ink
            : ink.withValues(alpha: 0.35);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(barWidth / 2)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) {
    return fraction != oldDelegate.fraction ||
        ink != oldDelegate.ink ||
        !listEquals(bars, oldDelegate.bars);
  }
}
