import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../domain/conversation.dart';
import '../domain/staff_registry.dart';
import '../domain/staff_registry_repository.dart';
import 'chat_controllers.dart';

/// Provider for the repository used to load and refresh staff registry data.
final staffRegistryRepositoryProvider = Provider<StaffRegistryRepository>(
  (_) => throw UnimplementedError('override in main'),
);

/// Notifier that manages the current [StaffRegistry] state.
///
/// Watches the current session and loads the registry from cache or remote
/// if the user is allowed to see it.
class StaffRegistryNotifier extends Notifier<StaffRegistry> {
  @override
  StaffRegistry build() {
    final session = ref.watch(sessionControllerProvider).value;
    final repo = ref.read(staffRegistryRepositoryProvider);

    if (session is! Allowed) {
      unawaited(repo.clear());
      return StaffRegistry.empty;
    }

    unawaited(_load());
    return StaffRegistry.empty;
  }

  Future<void> _load() async {
    final stored = await ref.read(staffRegistryRepositoryProvider).cached();
    if (!ref.mounted) return;
    if (stored != null) state = stored;
    await refresh();
  }

  /// Refreshes the [StaffRegistry] from the repository.
  ///
  /// If the result is [Ok], the state is updated. If it is [Err], the
  /// existing state is kept. If the notifier is unmounted during the
  /// operation, no state change occurs.
  Future<void> refresh() async {
    final r = await ref.read(staffRegistryRepositoryProvider).refresh();
    if (!ref.mounted) return;
    if (r is Ok<StaffRegistry>) state = r.value;
  }
}

/// Provider for the [StaffRegistryNotifier].
final staffRegistryProvider =
    NotifierProvider<StaffRegistryNotifier, StaffRegistry>(
      StaffRegistryNotifier.new,
    );

/// The staff commands of one conversation (empty for a normal chat).
final staffCommandsProvider = Provider.family<List<StaffCommand>, String>((
  ref,
  conversationId,
) {
  final conversations = ref.watch(conversationListProvider).value ?? const [];
  Conversation? target;
  for (final c in conversations) {
    if (c.id == conversationId) {
      target = c;
      break;
    }
  }
  return ref.watch(staffRegistryProvider).commandsFor(target?.staffKey);
});
