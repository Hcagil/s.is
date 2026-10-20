import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_foundation/path_provider_foundation.dart';

/// The database file name; its -wal and -shm files sit beside it.
const storeFileName = 'sis_store.sqlite';

/// The iOS App Group the app and its extensions share (see Runner.entitlements).
const storeAppGroup = 'group.com.esd.sis';

/// The ONE place that decides where the message database lives: the App Group container on iOS (so a notification extension can reach it later), the app support directory elsewhere (never the cache directory, which the OS may clear).
Future<File> storeFile({
  bool? isIos,
  Future<String?> Function(String group)? groupContainer,
  Future<Directory> Function()? supportDir,
}) async {
  final ios = isIos ?? Platform.isIOS;
  if (ios) {
    final path =
        await (groupContainer ??
            (g) => PathProviderFoundation().getContainerPath(
              appGroupIdentifier: g,
            ))(storeAppGroup);
    if (path != null) {
      return File(p.join(path, storeFileName));
    }
  }
  final dir = await (supportDir ?? getApplicationSupportDirectory)();
  return File(p.join(dir.path, storeFileName));
}

/// Sets an existing database file aside (and its -wal and -shm), renamed to `sis_store.orphan-UNIXSECONDS.sqlite` (plus -wal and -shm) in the same folder. Never deletes: used when the key that opened it is gone for good.
Future<void> setAsideStore(File file) async {
  final stamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final dir = p.dirname(file.path);
  for (final suffix in ['', '-wal', '-shm']) {
    final from = File('${file.path}$suffix');
    if (await from.exists()) {
      await from.rename(p.join(dir, 'sis_store.orphan-$stamp.sqlite$suffix'));
    }
  }
}
