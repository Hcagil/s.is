import 'dart:async';

import 'attachment.dart';
import 'video.dart';

/// One file handed to SIS by another app, already copied into this app's own cache.
final class SharedItem {
  /// Creates a shared item.
  const SharedItem({
    required this.path,
    required this.name,
    required this.isVideo,
  });

  /// File path in the app's own cache.
  final String path;

  /// File name.
  final String name;

  /// True when the file is a video.
  final bool isVideo;
}

/// What another app shared with SIS: text and/or photos and videos.
final class SharedContent {
  /// Creates shared content.
  const SharedContent({this.text = '', this.items = const []});

  /// Text that was shared.
  final String text;

  /// Files that were shared.
  final List<SharedItem> items;

  /// True when nothing was shared.
  bool get isEmpty => text.trim().isEmpty && items.isEmpty;

  /// Number of photos in the content.
  int get photoCount => items.where((i) => !i.isVideo).length;

  /// Number of videos in the content.
  int get videoCount => items.where((i) => i.isVideo).length;
}

/// The door other apps share through.
abstract interface class ShareIntake {
  /// Hands over what another app shared with SIS and forgets it; null when
  /// nothing waits.
  Future<SharedContent?> take();

  /// Fires when another share arrives while the app is already running.
  Stream<void> get arrivals;

  /// The photo [item] as send-ready bytes with its tiny preview; null when it
  /// cannot be read.
  Future<PickedImage?> readPhoto(SharedItem item);

  /// Deletes the cache files of [content] (sent, cancelled or replaced).
  Future<void> discard(SharedContent content);
}

/// Copies a shared video into the app's own folder like a picked one.
abstract interface class SharedVideoImporter {
  /// Copies [item] into its own message folder. Source null and tooLong true
  /// when over 5 minutes; both null/false when unreadable. Never throws.
  Future<({VideoSource? source, bool tooLong})> importVideo(SharedItem item);
}
