import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../../chat/data/store/store_key.dart';
import '../../chat/data/store/store_location.dart';
import 'pickle_key.dart';

/// iPhone start-up guard, run BEFORE the message store opens.
/// When the store file exists, its key is saved, but the Olm pickle key is gone from both keychain groups,
/// and the store holds an account pickle, those pickles can never be opened again:
/// the store is set aside (renamed, never deleted) and the store key is forgotten,
/// so a fresh store and keys are made.
/// Without pickles nothing is done (the pickle key is made when first needed).
/// Does nothing without an iOS keychain group, and never throws:
/// any problem leaves everything as it is.
Future<void> guardLostPickleKey({
  required String? group,
  required File file,
  required StoreKey storeKey,
  required PickleKey pickleKey,
}) async {
  if (group == null) return;

  try {
    if (!await file.exists()) return;
    final key = await storeKey.peek();
    if (key == null) return;
    if (await pickleKey.exists()) return;

    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    final bool hasPickles;
    try {
      db.execute("PRAGMA key = \"x'$key'\";");
      hasPickles = db
          .select("SELECT 1 FROM meta WHERE key = 'olm_account' LIMIT 1")
          .isNotEmpty;
    } finally {
      db.close();
    }

    if (!hasPickles) return;
    await setAsideStore(file);
    await storeKey.delete();
  } on Object {
    return;
  }
}
