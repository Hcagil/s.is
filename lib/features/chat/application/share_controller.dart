import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../domain/attachment.dart';
import '../domain/links.dart';
import '../domain/message.dart' show maxMessageLength;
import '../domain/shared_content.dart';
import 'chat_controllers.dart';
import 'chat_drafts.dart';
import 'link_preview_controller.dart';

/// The door other apps share through (set in main). Until then nothing is ever
/// shared, so a widget tree built without the host (tests) still works.
final shareIntakeProvider = Provider<ShareIntake>(
  (_) => const _NoShareIntake(),
);

/// A door nobody shares through.
class _NoShareIntake implements ShareIntake {
  const _NoShareIntake();

  @override
  Future<SharedContent?> take() async => null;

  @override
  Stream<void> get arrivals => const Stream<void>.empty();

  @override
  Future<PickedImage?> readPhoto(SharedItem item) async => null;

  @override
  Future<void> discard(SharedContent content) async {}
}

/// [text] cut to the message limit (UTF-16 units, like the check that drops longer messages), never in the middle of a surrogate pair (an emoji).
String _cutToLimit(String text) {
  if (text.length <= maxMessageLength) return text;
  var end = maxMessageLength;
  final last = text.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) end--;
  return text.substring(0, end);
}

/// Copies a shared video into the app's own folder like a picked one (set in main).
final sharedVideoImporterProvider = Provider<SharedVideoImporter>(
  (_) => throw UnimplementedError('override in main'),
);

/// The content shared by another app, or null when nothing is shared.
final pendingShareProvider = NotifierProvider<PendingShare, SharedContent?>(
  PendingShare.new,
);

/// Holds what another app shared until the member picks chats and taps Send.
/// Nothing leaves the phone before [send].
class PendingShare extends Notifier<SharedContent?> {
  @override
  SharedContent? build() {
    final intake = ref.read(shareIntakeProvider);
    final sub = intake.arrivals.listen((_) => unawaited(_fetch()));
    ref.onDispose(sub.cancel);
    unawaited(_fetch());
    return null;
  }

  /// Takes the next shared content from the host app.
  Future<void> _fetch() async {
    final got = await ref.read(shareIntakeProvider).take();
    if (got == null || !ref.mounted) return;
    // shortcut: a share replaced before its page ever opened leaves its cache
    // files to the system's cache cleaning; one still open is cleaned by finish.
    state = got;
  }

  /// The page for [shown] is closed, sent or not: its files go. A newer share
  /// that arrived meanwhile stays.
  Future<void> finish(SharedContent shown) async {
    if (identical(state, shown)) state = null;
    await ref.read(shareIntakeProvider).discard(shown);
  }

  /// Sends [content] to [chatIds] and to [personIds] (people with no chat yet
  /// get one first). One [caption] for all: it goes with the text when there
  /// are no files, else on the first photo, else as its own message. Text is
  /// queued like a typed message (link card included), videos are queued and
  /// shrunk, photos go at once. [tooLong] counts videos over 5 minutes and
  /// [unreadable] photos that could not be read; both were left out. A chat that fails does not stop the others.
  Future<({Result<void> result, int tooLong, int unreadable})> send(
    SharedContent content, {
    required List<String> chatIds,
    required List<String> personIds,
    required String caption,
  }) async {
    final ids = [...chatIds];
    for (final person in personIds) {
      final started = await ref
          .read(conversationListProvider.notifier)
          .startWith(person);
      switch (started) {
        case Ok(:final value):
          if (!ids.contains(value)) ids.add(value);
        case Err(:final failure):
          return (result: Err<void>(failure), tooLong: 0, unreadable: 0);
      }
    }

    final cap = _cutToLimit(caption.trim());
    final intake = ref.read(shareIntakeProvider);
    final queue = ref.read(sendQueueProvider.notifier);
    final body = _cutToLimit(
      [
        if (cap.isNotEmpty && content.items.isEmpty) cap,
        if (content.text.trim().isNotEmpty) content.text.trim(),
      ].join('\n'),
    );
    // The link card is read once for all chats; sending never waits longer.
    final link = extractLinks(body).firstOrNull;
    final draft = link == null
        ? null
        : await ref.read(linkPreviewFetcherProvider).fetch(link);

    final photos = <PickedImage>[];
    var unreadable = 0;
    for (final item in content.items) {
      if (item.isVideo) continue;
      final p = await intake.readPhoto(item);
      if (p == null) {
        unreadable++;
      } else {
        photos.add(p);
      }
    }

    Failure? failure;
    final tooLong = <SharedItem>{};
    for (final id in ids) {
      if (body.isNotEmpty) queue.enqueue(id, body: body, preview: draft);
      var captionLeft = content.items.isEmpty ? '' : cap;
      // The caption rides the first readable photo; with none (all unreadable, or a video first) it is its own message.
      if (captionLeft.isNotEmpty &&
          (photos.isEmpty || content.items.first.isVideo)) {
        queue.enqueue(id, body: captionLeft);
        captionLeft = '';
      }
      for (var i = 0; i < photos.length; i++) {
        final r = await ref
            .read(chatRepositoryProvider)
            .sendImage(
              conversationId: id,
              image: photos[i],
              body: i == 0 ? captionLeft : '',
            );
        if (r case Err(failure: final f)) {
          failure ??= f;
          break;
        }
      }
      for (final item in content.items) {
        if (!item.isVideo || tooLong.contains(item)) continue;
        // One copy per message: each message owns and later deletes its own folder.
        final imported = await ref
            .read(sharedVideoImporterProvider)
            .importVideo(item);
        final source = imported.source;
        if (source != null) {
          queue.enqueueVideo(id, source);
        } else if (imported.tooLong) {
          tooLong.add(item);
        } else {
          failure ??= const VideoFailedFailure();
        }
      }
    }
    unawaited(ref.read(conversationListProvider.notifier).reloadQuietly());
    return (
      result: failure == null ? const Ok<void>(null) : Err<void>(failure),
      tooLong: tooLong.length,
      unreadable: unreadable,
    );
  }
}
