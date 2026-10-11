import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/sticker.dart';
import 'message_menu_card.dart';

/// Returns a user-facing error message for a sticker-related failure.
String stickerFailureText(AppLocalizations l, Failure failure) {
  return switch (failure) {
    StickerLimitFailure(code: 'STKA1') => l.stickerLimitAlbums(
      maxStickerAlbums,
    ),
    StickerLimitFailure(code: 'STKA2') => l.stickerLimitInAlbum(
      maxAlbumStickers,
    ),
    StickerLimitFailure(code: 'STKF1') => l.stickerLimitFavourites(
      maxFavouriteStickers,
    ),
    _ => failure.message,
  };
}

Rect _centre(BuildContext context) => Rect.fromCenter(
  center: MediaQuery.sizeOf(context).center(Offset.zero),
  width: 1,
  height: 1,
);

/// Shows a card to enter an album name; returns the trimmed name, or null.
Future<String?> showAlbumNameCard(
  BuildContext context, {
  String initial = '',
  required String title,
  required String action,
}) {
  return showFloatingCard<String>(
    context,
    anchor: _centre(context),
    highlightAnchor: false,
    cardKey: const ValueKey('album-name-card'),
    child: _AlbumNameForm(initial: initial, title: title, action: action),
  );
}

class _AlbumNameForm extends StatefulWidget {
  const _AlbumNameForm({
    required this.initial,
    required this.title,
    required this.action,
  });

  final String initial;
  final String title;
  final String action;

  @override
  State<_AlbumNameForm> createState() => _AlbumNameFormState();
}

class _AlbumNameFormState extends State<_AlbumNameForm> {
  late final TextEditingController _controller;
  bool _empty = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _empty = true);
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SizedBox(
      width: 280,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.title,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('album-name-field'),
              controller: _controller,
              autofocus: true,
              maxLength: 30,
              decoration: InputDecoration(hintText: l.stickerAlbumNameHint),
              onChanged: (_) {
                if (_empty) setState(() => _empty = false);
              },
              onSubmitted: (_) => _submit(),
            ),
            if (_empty)
              Text(
                l.stickerAlbumNameHint,
                key: const ValueKey('album-name-empty'),
                style: TextStyle(
                  color: SisBrand.of(context).danger,
                  fontSize: 12,
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('album-name-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l.stickerCancel),
                ),
                TextButton(
                  key: const ValueKey('album-name-ok'),
                  onPressed: _submit,
                  child: Text(widget.action),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Adds a sticker to an album, asking which one (or to make a new one).
Future<void> addStickerToAlbumFlow(
  BuildContext context,
  WidgetRef ref,
  String stickerId,
) async {
  final l = AppLocalizations.of(context);
  if (!ref.read(stickerLibraryProvider).loaded) {
    await ref.read(stickerLibraryProvider.notifier).refresh();
    if (!context.mounted) return;
  }
  final albums = ref.read(stickerLibraryProvider).albums;
  final picked = await showMenuCard<String>(
    context,
    anchor: _centre(context),
    highlightAnchor: false,
    cardKey: const ValueKey('album-picker'),
    actions: [
      for (final a in albums)
        MenuCardAction<String>(
          value: a.id,
          keyId: 'album-${a.id}',
          icon: Icons.photo_album_outlined,
          label: a.name,
        ),
      MenuCardAction<String>(
        value: '',
        keyId: 'album-new',
        icon: Icons.add,
        label: l.stickerNewAlbum,
      ),
    ],
  );
  if (picked == null || !context.mounted) return;

  var albumId = picked;
  var albumName = '';
  if (picked.isEmpty) {
    final name = await showAlbumNameCard(
      context,
      title: l.stickerNewAlbum,
      action: l.stickerAlbumCreate,
    );
    if (name == null || !context.mounted) return;
    final made = await ref
        .read(stickerLibraryProvider.notifier)
        .createAlbum(name);
    if (!context.mounted) return;
    final failed = made.failure;
    if (failed != null || made.id == null) {
      if (failed != null) {
        showSisNotice(context, stickerFailureText(l, failed), isError: true);
      }
      return;
    }
    albumId = made.id!;
    albumName = name;
  } else {
    albumName = albums.firstWhere((a) => a.id == picked).name;
  }

  final failure = await ref
      .read(stickerLibraryProvider.notifier)
      .addToAlbum(albumId, stickerId);
  if (!context.mounted) return;
  showSisNotice(
    context,
    failure == null
        ? l.stickerAddedAlbum(albumName)
        : stickerFailureText(l, failure),
    isError: failure != null,
  );
}
