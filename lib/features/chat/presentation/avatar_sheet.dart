import 'package:flutter/material.dart';

import '../domain/attachment.dart';
import 'attachment_sheet.dart';
import 'crop_screen.dart';

/// What the avatar sheet decided: a new picture to upload, a request to
/// remove the current one, or null when the member closed the sheet without
/// choosing either.
sealed class AvatarChoice {}

/// The member picked [image] as the new picture.
final class AvatarPicked implements AvatarChoice {
  const AvatarPicked(this.image);
  final PickedImage image;
}

/// The member asked to remove the current picture.
final class AvatarRemoved implements AvatarChoice {
  const AvatarRemoved();
}

/// "Choose photo" (opens the app's own gallery grid, centre-cropped square)
/// and, only when [hasAvatar], "Remove photo". Null when the member backs
/// out of either sheet without deciding.
Future<AvatarChoice?> showAvatarSheet(
  BuildContext context, {
  required bool hasAvatar,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('avatar-choose'),
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Choose photo'),
            onTap: () => Navigator.of(sheet).pop('choose'),
          ),
          if (hasAvatar)
            ListTile(
              key: const ValueKey('avatar-remove'),
              leading: Icon(
                Icons.delete_outline,
                color: Theme.of(sheet).colorScheme.error,
              ),
              title: Text(
                'Remove photo',
                style: TextStyle(color: Theme.of(sheet).colorScheme.error),
              ),
              onTap: () => Navigator.of(sheet).pop('remove'),
            ),
        ],
      ),
    ),
  );
  switch (action) {
    case 'remove':
      return const AvatarRemoved();
    case 'choose':
      if (!context.mounted) return null;
      final picked = await showAttachmentSheet(context, square: true);
      if (picked.images.isEmpty || !context.mounted) return null;
      final cropped = await openCropScreen(context, picked.images.first);
      return cropped == null ? null : AvatarPicked(cropped);
    default:
      return null;
  }
}
