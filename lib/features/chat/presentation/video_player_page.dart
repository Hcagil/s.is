import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/video.dart';

/// Opens the full-screen player for the video file at [path].
Future<void> openVideoPlayer(BuildContext context, String path) =>
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 200),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, _, _) => VideoPlayerPage(path: path),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );

/// Black full-screen video player: close, mute, scrub bar, play/pause, share.
class VideoPlayerPage extends ConsumerStatefulWidget {
  /// Creates the player for the video at [path].
  const VideoPlayerPage({required this.path, super.key});

  /// The local video file.
  final String path;

  @override
  ConsumerState<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends ConsumerState<VideoPlayerPage> {
  late final VideoPlayback _playback = ref
      .read(videoPlaybackFactoryProvider)
      .create();
  bool _muted = false;
  bool _ready = false;
  double? _drag;

  @override
  void initState() {
    super.initState();
    _open();
  }

  @override
  void dispose() {
    _playback.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final ok = await _playback.open(widget.path);
    if (!mounted) return;
    if (!ok) {
      showSisNotice(
        context,
        AppLocalizations.of(context).videoCannotPlay,
        isError: true,
      );
      Navigator.of(context).maybePop();
      return;
    }
    setState(() => _ready = true);
    await _playback.play();
  }

  void _toggle(VideoPlaybackState state) {
    if (state.playing) {
      _playback.pause();
    } else {
      if (state.finished) _playback.seekTo(Duration.zero);
      _playback.play();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final brand = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: StreamBuilder<VideoPlaybackState>(
          stream: _playback.states,
          initialData: const VideoPlaybackState(),
          builder: (context, snapshot) {
            final state = snapshot.data ?? const VideoPlaybackState();
            final total = state.duration.inMilliseconds.toDouble();
            final max = total < 1 ? 1.0 : total;
            final value = (_drag ?? state.position.inMilliseconds.toDouble())
                .clamp(0.0, max);
            const small = TextStyle(color: Colors.white70, fontSize: 12);
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: Row(
                    children: [
                      IconButton(
                        key: const ValueKey('video-close'),
                        tooltip: l.videoClose,
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                      const Spacer(),
                      IconButton(
                        key: const ValueKey('video-mute'),
                        tooltip: _muted ? l.videoUnmute : l.videoMute,
                        icon: Icon(
                          _muted
                              ? Icons.volume_off_rounded
                              : Icons.volume_up_rounded,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          setState(() => _muted = !_muted);
                          _playback.setMuted(_muted);
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _toggle(state),
                    child: Center(
                      child: _ready
                          ? ref.watch(videoSurfaceProvider)(_playback) as Widget
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          activeTrackColor: brand,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7,
                          ),
                          overlayShape: SliderComponentShape.noOverlay,
                        ),
                        child: Slider(
                          key: const ValueKey('video-scrub'),
                          max: max,
                          value: value,
                          onChanged: (v) => setState(() => _drag = v),
                          onChangeEnd: (v) {
                            _playback.seekTo(Duration(milliseconds: v.round()));
                            setState(() => _drag = null);
                          },
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            durationLabel(state.position.inMilliseconds),
                            style: small,
                          ),
                          Text(
                            durationLabel(state.duration.inMilliseconds),
                            style: small,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Material(
                        color: brand,
                        shape: const CircleBorder(),
                        child: InkWell(
                          key: const ValueKey('video-playpause'),
                          customBorder: const CircleBorder(),
                          onTap: () => _toggle(state),
                          child: Semantics(
                            button: true,
                            label: state.playing ? l.videoPause : l.videoPlay,
                            child: SizedBox(
                              width: 56,
                              height: 56,
                              child: Icon(
                                state.playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 32,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 20),
                      Material(
                        color: Colors.white.withValues(alpha: 0.18),
                        shape: const StadiumBorder(),
                        child: InkWell(
                          key: const ValueKey('video-share'),
                          customBorder: const StadiumBorder(),
                          onTap: () =>
                              ref.read(videoSharerProvider).share(widget.path),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 18,
                              vertical: 12,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.ios_share_rounded,
                                  color: Colors.white,
                                  size: 18,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  l.videoShare,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
