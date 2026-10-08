// A fake of the VideoGallery boundary, written by QA from the interface in
// lib/features/chat/domain/video_gallery.dart only. It is inconvenient like
// the real library: the permission answer arrives late, each page arrives
// late, a thumbnail may never be readable, and prepare() is held until the
// test answers it -- so a page that assumed an instant answer shows it.
import 'dart:async';
import 'dart:typed_data';

import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/video.dart';
import 'package:sis/features/chat/domain/video_gallery.dart';

/// `count` videos named `<prefix>0..`, each [durationMs] long.
List<GalleryVideo> galleryVideos(
  int count, {
  String prefix = 'v',
  int durationMs = 41000,
}) => [
  for (var i = 0; i < count; i++)
    GalleryVideo(id: '$prefix$i', durationMs: durationMs),
];

/// One prepare() asked of the library, waiting for the test's answer.
class PrepareAsk {
  PrepareAsk(this.chosen);
  final List<GalleryVideo> chosen;
  final answer = Completer<VideoPick>();
}

class VideoGalleryFake implements VideoGallery {
  VideoGalleryFake({
    this.access = GalleryAccess.full,
    List<GalleryVideo> videos = const [],
    this.latency = const Duration(milliseconds: 20),
  }) : videos = [...videos];

  /// What the next requestAccess answers.
  GalleryAccess access;

  /// The library, newest first, as the member allowed it.
  List<GalleryVideo> videos;

  /// How late every answer (access, page, thumbnail) arrives.
  final Duration latency;

  /// Pages that fail (throw) when asked: a broken library read. The contract
  /// says the real one never throws, so this is the page's own safety net.
  final failingPages = <int>{};

  /// What selectMore changes the library to (the system sheet's result).
  List<GalleryVideo>? afterSelectMore;

  int accessRequests = 0;
  int settingsOpened = 0;
  int selectMores = 0;
  final pagesAsked = <({int page, int count})>[];
  final prepares = <PrepareAsk>[];

  Future<void> _late() => Future<void>.delayed(latency);

  @override
  Future<GalleryAccess> requestAccess() async {
    accessRequests++;
    await _late();
    return access;
  }

  @override
  Future<List<GalleryVideo>> recent({int page = 0, int count = 60}) async {
    pagesAsked.add((page: page, count: count));
    await _late();
    if (failingPages.contains(page)) {
      throw StateError('library read failed');
    }
    if (access != GalleryAccess.full && access != GalleryAccess.limited) {
      return const [];
    }
    return videos.skip(page * count).take(count).toList();
  }

  @override
  Future<Uint8List?> thumbnail(GalleryVideo video, {int size = 240}) async {
    await _late();
    return null; // unreadable: the tile must still show and be tappable
  }

  @override
  Future<void> selectMore() async {
    selectMores++;
    await _late();
    if (afterSelectMore != null) videos = [...afterSelectMore!];
  }

  @override
  Future<void> openSettings() async {
    settingsOpened++;
    await _late();
  }

  @override
  Future<VideoPick> prepare(List<GalleryVideo> chosen) {
    final ask = PrepareAsk(List.of(chosen));
    prepares.add(ask);
    return ask.answer.future;
  }
}
