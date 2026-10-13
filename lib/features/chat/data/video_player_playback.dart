import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import '../domain/video.dart';
import '../domain/voice.dart';

/// A [VideoPlayback] backed by the video_player package.
final class VideoPlayerPlayback implements VoicePlayback {
  VideoPlayerController? _controller;
  final _states = StreamController<VideoPlaybackState>.broadcast();

  /// The controller the video surface draws; null until opened.
  VideoPlayerController? get controller => _controller;

  @override
  Future<bool> open(String path) async {
    final old = _controller;
    _controller = null;
    old?.removeListener(_emit);
    await old?.dispose();

    final c = VideoPlayerController.file(File(path));
    var ok = true;
    try {
      await c.initialize();
    } catch (e) {
      log('Opening a video failed: ${e.runtimeType}', name: 'sis.video');
      ok = false;
    }
    if (!ok) {
      await c.dispose();
      return false;
    }
    _controller = c;
    c.addListener(_emit);
    _emit();
    return true;
  }

  void _emit() {
    final c = _controller;
    if (_states.isClosed || c == null) return;
    final v = c.value;
    _states.add(
      VideoPlaybackState(
        position: v.position,
        duration: v.duration,
        playing: v.isPlaying,
        finished: v.isCompleted,
      ),
    );
  }

  @override
  Stream<VideoPlaybackState> get states => _states.stream;

  @override
  Future<void> play() async {
    try {
      await _controller?.play();
    } catch (e) {
      log('Video playback failed: ${e.runtimeType}', name: 'sis.video');
    }
  }

  @override
  Future<void> pause() async {
    try {
      await _controller?.pause();
    } catch (e) {
      log('Video playback failed: ${e.runtimeType}', name: 'sis.video');
    }
  }

  @override
  Future<void> seekTo(Duration position) async {
    try {
      await _controller?.seekTo(position);
    } catch (e) {
      log('Video playback failed: ${e.runtimeType}', name: 'sis.video');
    }
  }

  @override
  Future<void> setMuted(bool muted) async {
    try {
      await _controller?.setVolume(muted ? 0 : 1);
    } catch (e) {
      log('Video playback failed: ${e.runtimeType}', name: 'sis.video');
    }
  }

  @override
  Future<void> setSpeed(double speed) async {
    try {
      await _controller?.setPlaybackSpeed(speed);
    } catch (e) {
      log('Video playback failed: ${e.runtimeType}', name: 'sis.video');
    }
  }

  @override
  Future<void> dispose() async {
    final c = _controller;
    _controller = null;
    c?.removeListener(_emit);
    try {
      await c?.dispose();
      await _states.close();
    } catch (e) {
      log('Closing a video failed: ${e.runtimeType}', name: 'sis.video');
    }
  }
}

/// Makes a [VideoPlayerPlayback] for each player screen.
final class VideoPlayerPlaybackFactory implements VideoPlaybackFactory {
  /// Creates the factory.
  const VideoPlayerPlaybackFactory();

  @override
  VideoPlayback create() => VideoPlayerPlayback();
}

/// Makes the video player used as a voice message player.
final class VoicePlayerPlaybackFactory implements VoicePlaybackFactory {
  /// Creates the factory.
  const VoicePlayerPlaybackFactory();

  @override
  VoicePlayback create() => VideoPlayerPlayback();
}

/// The picture of a playing video; main.dart hands it to the player page.
Widget videoSurface(VideoPlayback playback) {
  final c = playback is VideoPlayerPlayback ? playback.controller : null;
  if (c == null || !c.value.isInitialized) return const SizedBox.shrink();
  return AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c));
}
