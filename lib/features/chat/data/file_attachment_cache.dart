import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../domain/attachment.dart';

/// Photos kept in the app's cache directory, one file per storage path.
/// The OS may clear that directory when space runs low; a missing photo
/// is simply downloaded again.
final class FileAttachmentCache implements AttachmentCache {
  FileAttachmentCache({Future<Directory> Function()? root})
    : _root = root ?? getApplicationCacheDirectory;

  // ponytail: no size cap; the OS clears the cache directory under storage
  // pressure. Add LRU eviction if the cache is ever reported large.
  final Future<Directory> Function() _root;

  Future<Directory> _dir() async =>
      Directory('${(await _root()).path}/attachments');

  // One flat file per storage path; encodeComponent keeps '/' out of the name.
  Future<File> _file(String path) async =>
      File('${(await _dir()).path}/${Uri.encodeComponent(path)}');

  @override
  Future<Uint8List?> read(String path) async {
    final f = await _file(path);
    try {
      return await f.readAsBytes();
    } on FileSystemException {
      return null; // not cached
    }
  }

  @override
  Future<void> write(String path, Uint8List bytes) async {
    try {
      final file = await _file(path);
      await file.parent.create(recursive: true);
      // Written aside, then renamed: a half-written file is never read as a
      // photo.
      final part = File('${file.path}.part');
      await part.writeAsBytes(bytes);
      await part.rename(file.path);
    } on FileSystemException {
      // A full disk only costs the cache.
    }
  }

  @override
  Future<void> clear() async {
    try {
      final d = await _dir();
      if (await d.exists()) await d.delete(recursive: true);
    } on FileSystemException {
      // Nothing to clear, or nothing that can be.
    }
  }
}
