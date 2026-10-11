import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../application/share_controller.dart';
import '../domain/shared_content.dart';
import 'forward_page.dart';

/// Opens the share target picker for [content] (the forward page, with a real
/// caption field), then sends it to everything the member ticked. People
/// without a chat yet get one created on send. Backing out sends nothing.
Future<void> showSharePage(
  BuildContext context,
  WidgetRef ref,
  SharedContent content,
) async {
  final l = AppLocalizations.of(context);
  // Not disposed on purpose: the page is still animating out when this
  // returns, and the controller holds no listeners.
  final caption = TextEditingController();
  final stripText = content.items.isEmpty
      ? content.text.trim()
      : content.videoCount == 0
      ? l.sharePhotos(content.photoCount)
      : content.photoCount == 0
      ? l.shareVideos(content.videoCount)
      : l.shareItems(content.items.length);
  final chosen = await Navigator.of(context)
      .push<({List<String> chatIds, List<String> personIds})>(
        MaterialPageRoute(
          builder: (_) => ForwardPage(
            exclude: null,
            title: l.shareTitle,
            stripText: stripText,
            stripLeading: _StripThumb(content: content),
            captionController: caption,
          ),
        ),
      );
  final pending = ref.read(pendingShareProvider.notifier);
  if (chosen == null ||
      (chosen.chatIds.isEmpty && chosen.personIds.isEmpty) ||
      !context.mounted) {
    await pending.finish(content);
    return;
  }
  showSisNotice(context, l.shareSending);
  final out = await pending.send(
    content,
    chatIds: chosen.chatIds,
    personIds: chosen.personIds,
    caption: caption.text,
  );
  await pending.finish(content);
  if (!context.mounted) return;
  if (out.tooLong > 0) {
    showSisNotice(context, l.videoTooLong(out.tooLong), isError: true);
  }
  if (out.unreadable > 0) {
    showSisNotice(context, l.shareUnreadable(out.unreadable), isError: true);
  }
  final total = chosen.chatIds.length + chosen.personIds.length;
  switch (out.result) {
    case Ok():
      showSisNotice(context, l.shareDone(total));
    case Err(:final failure):
      showSisNotice(context, failure.message, isError: true);
  }
}

/// The small picture at the left of the strip: the first photo, else a mark
/// for a video or for text.
class _StripThumb extends StatelessWidget {
  const _StripThumb({required this.content});

  final SharedContent content;

  @override
  Widget build(BuildContext context) {
    final photo = content.items.where((i) => !i.isVideo).firstOrNull;
    return ClipRRect(
      key: const ValueKey('share-strip-thumb'),
      borderRadius: BorderRadius.circular(5),
      child: photo != null
          ? Image.file(
              File(photo.path),
              width: 22,
              height: 22,
              fit: BoxFit.cover,
              cacheWidth: 66,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.photo_outlined, size: 20),
            )
          : content.videoCount > 0
          ? const Icon(Icons.videocam_outlined, size: 20)
          : const Icon(Icons.notes_outlined, size: 20),
    );
  }
}

/// Wraps Home: opens the share page when something was shared with the app
/// and the member is signed in and past first-run.
class ShareHost extends ConsumerStatefulWidget {
  /// Wraps [child].
  const ShareHost({super.key, required this.child});

  /// The screen shown underneath.
  final Widget child;

  @override
  ConsumerState<ShareHost> createState() => _ShareHostState();
}

class _ShareHostState extends ConsumerState<ShareHost> {
  bool _open = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_check()));
  }

  Future<void> _check() async {
    if (_open || !mounted) return;
    final content = ref.read(pendingShareProvider);
    if (content == null) return;
    _open = true;
    await showSharePage(context, ref, content);
    _open = false;
    // A newer share may have arrived while this one was open.
    if (mounted) unawaited(_check());
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(pendingShareProvider, (_, next) {
      if (next != null) unawaited(_check());
    });
    return widget.child;
  }
}
