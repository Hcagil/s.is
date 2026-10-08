import 'dart:developer';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../domain/file_attachment.dart';
import '../domain/file_repository.dart';
import '../domain/message.dart';

/// Files kept in the app's documents directory, organized by message ID.
final class FlutterDeviceFiles implements DeviceFiles {
  /// Creates a file manager with an optional root directory.
  FlutterDeviceFiles({Future<Directory> Function()? root})
      : _root = root ?? getApplicationDocumentsDirectory;

  final Future<Directory> Function() _root;

  Future<Directory> _dir() async =>
      Directory('${(await _root()).path}/files');

  @override
  Future<FilePick> pick() async {
    try {
      final picked = await FilePicker.pickFiles();
      var tooBig = 0;
      final files = <PickedFile>[];
      for (final f in picked) {
        final size = f.lengthSync() ?? await f.length();
        if (size == null || size <= 0) continue;
        if (size > maxFileBytes) {
          tooBig++;
          continue;
        }
        final id = randomMessageId();
        final name = safeFileName(f.name);
        final dest = File('${(await _dir()).path}/$id/$name');
        try {
          await dest.parent.create(recursive: true);
          final sink = dest.openWrite();
          await sink.addStream(f.readAsByteStream());
          await sink.close();
          files.add(PickedFile(
            id: id,
            path: dest.path,
            name: name,
            mime: lookupMimeType(name) ?? 'application/octet-stream',
            size: await dest.length(),
          ));
        } catch (e) {
          log('Copying a picked file failed: ${e.runtimeType}', name: 'sis.files');
          try {
            await dest.parent.delete(recursive: true);
          } catch (_) {}
        }
      }
      return FilePick(files: files, tooBig: tooBig);
    } catch (e) {
      log('Picking files failed: ${e.runtimeType}', name: 'sis.files');
      return const FilePick();
    }
  }

  @override
  Future<String?> storedPath(String messageId, String name) async {
    final f = File('${(await _dir()).path}/$messageId/${safeFileName(name)}');
    return await f.exists() ? f.path : null;
  }

  @override
  Future<String> pathFor(String messageId, String name) async {
    final dir = Directory('${(await _dir()).path}/$messageId');
    await dir.create(recursive: true);
    return '${dir.path}/${safeFileName(name)}';
  }

  @override
  Future<bool> open(String path) async {
    try {
      final r = await OpenFilex.open(path);
      return r.type == ResultType.done;
    } catch (_) {
      return false;
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
