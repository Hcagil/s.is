import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/swipe_back.dart';
import '../../../app/theme.dart';
import '../domain/attachment.dart';
import '../domain/message.dart';

/// Opens the full-screen preview of [images] with [caption] prefilled. Returns
/// what is left of the photos and the caption when the member taps Send, or
/// null when they go back (nothing is sent).
Future<({List<PickedImage> images, String caption})?> showAttachmentPreview(
  BuildContext context, {
  required List<PickedImage> images,
  String caption = '',
}) => Navigator.of(context).push<({List<PickedImage> images, String caption})>(
  MaterialPageRoute(
    settings: noSwipeBack,
    builder: (_) => AttachmentPreviewPage(images: images, caption: caption),
  ),
);

/// The photo(s) about to be sent: swipe between them, drop one, write a
/// caption, send. Follows the app theme.
class AttachmentPreviewPage extends StatefulWidget {
  const AttachmentPreviewPage({
    super.key,
    required this.images,
    this.caption = '',
  });

  final List<PickedImage> images;
  final String caption;

  @override
  State<AttachmentPreviewPage> createState() => _AttachmentPreviewPageState();
}

/// Bytes that cannot be decoded as a picture show a quiet tile, never a throw.
Widget _undecodable(BuildContext context, Object error, StackTrace? stack) {
  final scheme = Theme.of(context).colorScheme;
  return ColoredBox(
    color: scheme.surfaceContainerHigh,
    child: Center(
      child: Icon(Icons.broken_image_outlined, color: scheme.onSurfaceVariant),
    ),
  );
}

class _AttachmentPreviewPageState extends State<AttachmentPreviewPage> {
  late final List<PickedImage> _images = List.of(widget.images);
  late final _caption = TextEditingController(text: widget.caption);
  final _pager = PageController();
  int _page = 0;

  @override
  void dispose() {
    _pager.dispose();
    _caption.dispose();
    super.dispose();
  }

  void _removeCurrent() {
    setState(() {
      _images.removeAt(_page);
      if (_page >= _images.length) _page = _images.length - 1;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_pager.hasClients) _pager.jumpToPage(_page);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    final many = _images.length > 1;
    return Scaffold(
      key: const ValueKey('preview-page'),
      appBar: AppBar(
        leading: BackButton(
          key: const ValueKey('preview-back'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: many
            ? Text(
                '${_page + 1} / ${_images.length}',
                key: const ValueKey('preview-count'),
              )
            : null,
        actions: [
          if (many)
            IconButton(
              key: const ValueKey('preview-remove'),
              icon: const Icon(Icons.delete_outline_rounded),
              tooltip: 'Remove this photo',
              onPressed: _removeCurrent,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              key: const ValueKey('preview-pager'),
              controller: _pager,
              itemCount: _images.length,
              onPageChanged: (p) => setState(() => _page = p),
              itemBuilder: (_, i) => Image.memory(
                _images[i].bytes,
                key: ValueKey('preview-photo-$i'),
                fit: BoxFit.contain,
                gaplessPlayback: true,
                errorBuilder: _undecodable,
              ),
            ),
          ),
          if (many)
            SizedBox(
              height: 64,
              child: ListView.separated(
                key: const ValueKey('preview-thumbs'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _images.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (_, i) => InkWell(
                  key: ValueKey('preview-thumb-$i'),
                  onTap: () => _pager.animateToPage(
                    i,
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeOut,
                  ),
                  child: Container(
                    width: 56,
                    height: 56,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: i == _page ? t.brand : Colors.transparent,
                        width: 2,
                      ),
                    ),
                    child: Image.memory(
                      _images[i].bytes,
                      fit: BoxFit.cover,
                      errorBuilder: _undecodable,
                    ),
                  ),
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('preview-caption'),
                      controller: _caption,
                      minLines: 1,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                      textCapitalization: TextCapitalization.sentences,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(maxMessageLength),
                      ],
                      decoration: const InputDecoration(
                        hintText: 'Add a caption',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    button: true,
                    label: 'Send',
                    child: InkWell(
                      key: const ValueKey('preview-send'),
                      customBorder: const CircleBorder(),
                      onTap: () => Navigator.of(context).pop((
                        images: List.of(_images),
                        caption: _caption.text.trim(),
                      )),
                      child: Ink(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: t.gradient,
                        ),
                        child: const Icon(
                          Icons.send_rounded,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
