import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../application/chat_drafts.dart';
import '../domain/sticker.dart';
import 'sticker_image.dart';

/// A page displaying the starter stickers for a conversation.
class StarterAlbumPage extends ConsumerWidget {
  /// Creates a [StarterAlbumPage] for the given [conversationId].
  const StarterAlbumPage({super.key, required this.conversationId});

  /// The ID of the conversation to send stickers to.
  final String conversationId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l.stickerTabStarter)),
      body: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: starterStickerIds.length,
        itemBuilder: (cell, i) {
          final id = starterStickerIds[i];
          return GestureDetector(
            key: ValueKey('starter-sticker-$id'),
            behavior: HitTestBehavior.opaque,
            onTap: () {
              ref
                  .read(sendQueueProvider.notifier)
                  .enqueueSticker(
                    conversationId,
                    id,
                    replyTo: ref.read(replyingToProvider),
                  );
              ref.read(stickerLibraryProvider.notifier).markUsed(id);
              Navigator.of(cell).pop();
            },
            child: StickerImage(stickerId: id, size: 72),
          );
        },
      ),
    );
  }
}
