import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/attachment.dart';
import '../domain/external_picker.dart';
import 'attachment_sheet.dart';
import 'crop_screen.dart';
import 'message_menu_card.dart';

/// What the avatar card decided: a new picture to upload, a request to
/// remove the current one, or null when the member closed the card without
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

/// Opens the picture card just under [anchor] (the picture's global rect):
/// "Take photo" (the camera, then the crop screen), "Choose from library"
/// (the photo grid, then the crop screen) and, only when [hasAvatar], "Remove
/// picture". Null when the member closes the card, or backs out of the
/// camera, grid or crop screen, without deciding.
Future<AvatarChoice?> showAvatarCard(
  BuildContext context,
  WidgetRef ref, {
  required Rect anchor,
  required bool hasAvatar,
}) async {
  final l = AppLocalizations.of(context);
  final action = await showMenuCard<String>(
    context,
    anchor: anchor,
    below: true,
    anchorRadius: 60,
    cardKey: const ValueKey('avatar-card'),
    actions: [
      MenuCardAction(
        value: 'camera',
        keyId: 'avatar-camera',
        rowKey: ValueKey('avatar-camera'),
        icon: Icons.photo_camera_outlined,
        label: l.avatarTakePhoto,
      ),
      MenuCardAction(
        value: 'library',
        keyId: 'avatar-library',
        rowKey: ValueKey('avatar-library'),
        icon: Icons.photo_library_outlined,
        label: l.avatarChoose,
      ),
      if (hasAvatar)
        MenuCardAction(
          value: 'remove',
          keyId: 'avatar-remove',
          rowKey: ValueKey('avatar-remove'),
          icon: Icons.delete_outline,
          label: l.avatarRemove,
          destructive: true,
        ),
    ],
  );
  if (!context.mounted) return null;
  switch (action) {
    case 'remove':
      return const AvatarRemoved();
    case 'library':
      final picked = await showAttachmentSheet(context, square: true);
      if (picked.images.isEmpty || !context.mounted) return null;
      // Already cropped by the sheet, which keeps the grid under the crop.
      return AvatarPicked(picked.images.first);
    case 'camera':
      final result = await ref.read(externalPickerProvider).takePhoto();
      if (!context.mounted) return null;
      switch (result) {
        case ExternalPickedImages(:final images) when images.isNotEmpty:
          final cropped = await openCropScreen(context, images.first);
          return cropped == null ? null : AvatarPicked(cropped);
        case ExternalPickCancelled():
          return null;
        case ExternalPickedImages() || ExternalPickFailed():
          showSisNotice(context, l.cameraFailed, isError: true);
          return null;
      }
    default:
      return null;
  }
}
