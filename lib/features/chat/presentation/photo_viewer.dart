import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/chat_controllers.dart';
import 'conversation_list.dart';

/// Opens [paths] full-screen at [index]: swipe between them, pinch to zoom.
Future<void> openPhotoViewer(
  BuildContext context,
  List<String> paths,
  int index,
) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => PhotoViewer(paths: paths, initialIndex: index),
  ),
);

/// Full-screen photos, dark whatever the theme: photos read best on black.
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.paths, this.initialIndex = 0});

  /// Attachment storage paths, in the order the caller shows them.
  final List<String> paths;
  final int initialIndex;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late final _pages = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          '${_index + 1} of ${widget.paths.length}',
          key: const ValueKey('viewer-position'),
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
      body: PageView.builder(
        key: const ValueKey('viewer-pages'),
        controller: _pages,
        itemCount: widget.paths.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) => _Photo(widget.paths[i]),
      ),
    );
  }
}

class _Photo extends ConsumerWidget {
  const _Photo(this.path);

  final String path;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    const white = TextStyle(color: Colors.white70);
    return switch (ref.watch(attachmentUrlProvider(path))) {
      AsyncData(:final value) => InteractiveViewer(
        maxScale: 5,
        child: Center(
          child: Image.network(
            value.toString(),
            key: ValueKey('viewer-image-$path'),
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                const Text('Image unavailable', style: white),
          ),
        ),
      ),
      AsyncError(:final error) => Center(
        child: Text(reasonOf(error), style: white),
      ),
      _ => const Center(child: CircularProgressIndicator(color: Colors.white)),
    };
  }
}
