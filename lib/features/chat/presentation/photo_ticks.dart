import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/notice.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/external_picker.dart';
import '../domain/gallery.dart';

/// The ticked photos of the attach sheet, shared with the big photo view so
/// there is one tick path.
class PhotoTicks extends ValueNotifier<List<GalleryPhoto>> {
  PhotoTicks() : super(const []);

  /// Ticks or unticks [p]. Over ExternalPicker.maxAttachments: shows the attachLimit notice and changes nothing. A new tick gives HapticFeedback.selectionClick().
  void toggle(BuildContext context, GalleryPhoto p) {
    final list = value;
    if (list.any((e) => e.id == p.id)) {
      value = [
        for (final e in list)
          if (e.id != p.id) e,
      ];
    } else if (list.length >= ExternalPicker.maxAttachments) {
      showSisNotice(
        context,
        AppLocalizations.of(context).attachLimit(ExternalPicker.maxAttachments),
      );
    } else {
      HapticFeedback.selectionClick();
      value = [...list, p];
    }
  }
}
