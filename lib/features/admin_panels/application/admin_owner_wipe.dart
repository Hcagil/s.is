import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import 'admin_panels_controller.dart';

/// Wipes what the admin panels keep on this phone when the session ends, like attachmentCacheOwnerProvider.
final adminOwnerWipeProvider = Provider<void>((ref) {
  ref.listen(sessionControllerProvider, (_, next) {
    switch (next.value) {
      case SignedOut() || Denied() || Replaced():
        unawaited(_wipe(ref));
      case _:
    }
  }, fireImmediately: true);
});

Future<void> _wipe(Ref ref) async {
  try {
    if (ref.exists(adminPanelsProvider)) {
      ref.read(adminPanelsProvider.notifier).lock();
    }
  } catch (_) {}

  try {
    await ref.read(adminPanelsRepositoryProvider).forget();
  } catch (_) {}

  try {
    await ref.read(adminSnapshotStoreProvider).clear();
  } catch (_) {}

  try {
    await ref.read(adminSeenStoreProvider).clear();
  } catch (_) {}
}
