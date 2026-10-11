import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../domain/link_preview.dart';
import '../domain/link_preview_fetcher.dart';
import '../domain/links.dart';
import 'chat_controllers.dart';
import 'chat_drafts.dart';

/// Reads a page once, on this phone, for the link card (set in main).
final linkPreviewFetcherProvider = Provider<LinkPreviewFetcher>(
  (_) => throw UnimplementedError('override in main'),
);

/// A link card ready to show in the strip above the composer.
final class ComposerLink {
  /// Creates a ready card.
  const ComposerLink({required this.url, required this.draft});

  /// The link the card is for.
  final Uri url;

  /// The card and its picture.
  final LinkPreviewDraft draft;
}

/// The card for the first link of the text being typed, or null when there is
/// none (no link, not ready yet, dismissed).
final composerLinkProvider =
    NotifierProvider.autoDispose<ComposerLinkController, ComposerLink?>(
      ComposerLinkController.new,
    );

/// Watches the typed text for a link and reads its page once, after a short
/// pause. Sending never waits for it: [takeForSend] hands over whatever is
/// ready at that moment.
class ComposerLinkController extends Notifier<ComposerLink?> {
  Timer? _timer;
  Uri? _watching;
  int _token = 0;
  final _dismissed = <String>{};

  @override
  ComposerLink? build() {
    ref.onDispose(() => _timer?.cancel());
    return null;
  }

  /// Called whenever the typed text changes.
  void onTextChanged(String text) {
    final first = extractLinks(text).firstOrNull;
    if (first == null || _dismissed.contains(first.toString())) {
      _forget();
      return;
    }
    if (_watching?.toString() == first.toString()) return;
    _timer?.cancel();
    _watching = first;
    final token = ++_token;
    state = null;
    _timer = Timer(const Duration(milliseconds: 500), () async {
      final draft = await ref.read(linkPreviewFetcherProvider).fetch(first);
      if (!ref.mounted || token != _token || draft == null) return;
      state = ComposerLink(url: first, draft: draft);
    });
  }

  /// The X on the strip: this link goes as plain text.
  void dismiss() {
    if (_watching != null) _dismissed.add(_watching.toString());
    _forget();
  }

  /// The card to send with [body], if it is ready and is for the first link of
  /// [body]; clears the strip either way.
  LinkPreviewDraft? takeForSend(String body) {
    final card = state;
    final first = extractLinks(body).firstOrNull;
    final draft =
        card != null && first != null && card.url.toString() == first.toString()
        ? card.draft
        : null;
    reset();
    return draft;
  }

  /// Forgets everything (another conversation, a sent message).
  void reset() {
    _dismissed.clear();
    _forget();
  }

  void _forget() {
    _timer?.cancel();
    _watching = null;
    _token++;
    state = null;
  }
}

/// One card picture: the one still waiting in the send queue, otherwise from
/// this phone or downloaded once. Kept alive so a card scrolled back into view
/// paints at once.
final linkImageProvider = FutureProvider.family<Uint8List, String>((
  ref,
  path,
) async {
  ref.watch(currentUserIdProvider);
  final pending = ref.read(sendQueueProvider.notifier).pendingLinkImage(path);
  if (pending != null) return pending;
  return switch (await ref.read(chatRepositoryProvider).linkImageBytes(path)) {
    Ok(:final value) => value,
    Err(:final failure) => throw failure,
  };
}, retry: (_, _) => null);
