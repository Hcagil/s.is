import 'package:image_picker/image_picker.dart';

import '../domain/attachment.dart';
import 'tiny_preview.dart';

/// [AttachmentSource] backed by the platform photo picker.
///
/// On Android 13+ the system photo picker needs no storage permission, so
/// nothing here asks for one.
final class ImagePickerAttachmentSource implements AttachmentSource {
  ImagePickerAttachmentSource(this._picker);

  final ImagePicker _picker;

  /// Long edge cap and quality are applied by the picker itself, so a 12 MP
  /// phone photo does not become a 6 MB upload on a phone connection.
  static const _maxEdge = 1600.0;
  static const _quality = 85;

  @override
  Future<PickedImage?> pickImage() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: _maxEdge,
      maxHeight: _maxEdge,
      imageQuality: _quality,
    );
    if (file == null) return null; // the member backed out
    final bytes = await file.readAsBytes();
    final name = file.name.toLowerCase();
    final extension = name.contains('.') ? name.split('.').last : 'jpg';
    return PickedImage(
      bytes: bytes,
      contentType: file.mimeType ?? _mimeFor(extension),
      extension: extension,
      preview: await tinyPreview(bytes),
    );
  }

  static String _mimeFor(String extension) => switch (extension) {
    'png' => 'image/png',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    _ => 'image/jpeg',
  };
}
