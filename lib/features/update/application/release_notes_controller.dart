import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../chat/application/chat_controllers.dart';
import '../domain/release_notes.dart';

/// Where release notes are asked for (Supabase in data/). Defaults to
/// nothing so a build without it still runs.
final releaseNotesDeliveryProvider = Provider<ReleaseNotesDelivery>(
  (_) => const _NoDelivery(),
);

final class _NoDelivery implements ReleaseNotesDelivery {
  const _NoDelivery();
  @override
  Future<Result<bool>> deliver(String userId) async => const Ok(false);
}

/// Asks for the "What's new" notes once per app start for whoever is signed
/// in. The delivery itself skips a build already served; a failure is not
/// shown and is retried at the next start, so it never blocks the app.
final releaseNotesProvider = NotifierProvider<ReleaseNotesController, void>(
  ReleaseNotesController.new,
);

class ReleaseNotesController extends Notifier<void> {
  @override
  void build() {
    final me = ref.watch(currentUserIdProvider);
    if (me == null) return;
    unawaited(_deliver(me));
  }

  Future<void> _deliver(String me) async {
    final r = await ref.read(releaseNotesDeliveryProvider).deliver(me);
    // The SIS chat now exists (or has a new message): show it in the list.
    if (r case Ok(value: true) when ref.mounted) {
      await ref.read(conversationListProvider.notifier).reloadQuietly();
    }
  }
}
