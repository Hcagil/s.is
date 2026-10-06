import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../domain/conversation.dart';
import '../domain/group_event.dart';
import '../domain/group_member.dart';
import '../domain/group_settings.dart';
import '../domain/group_settings_repository.dart';
import '../domain/message.dart';
import '../domain/timeline.dart';
import 'chat_controllers.dart';
import 'chat_drafts.dart';

/// Mirrors chat_controllers.dart's own `_never`: no automatic retry on a
/// failed build, so a refusal settles on [AsyncError] instead of spinning
/// forever. Private to this file the same way; not worth exporting a
/// one-liner both files would otherwise import.
Duration? _never(int retryCount, Object error) => null;

Future<T> _value<T>(Future<Result<T>> call) async => switch (await call) {
  Ok(:final value) => value,
  Err(:final failure) => throw failure,
};

/// A group's full roster, including anyone who has left or been removed
/// (greyed in the app) -- for the group page's members list. Refused
/// (AsyncError) for a 1:1 or a conversation the caller was never in, same as
/// every other family provider here.
final groupRosterProvider = FutureProvider.autoDispose
    .family<List<GroupMember>, String>((ref, conversationId) {
      ref.watch(currentUserIdProvider);
      return _value(
        ref.read(chatRepositoryProvider).groupRoster(conversationId),
      );
    }, retry: _never);

/// "X left" / "X was removed" / "X was added" for a group -- empty for
/// anyone but a current admin (the server's row-level security decides
/// that, not this provider) and always empty for a 1:1.
final groupEventsProvider = FutureProvider.autoDispose
    .family<List<GroupEvent>, String>((ref, conversationId) {
      ref.watch(currentUserIdProvider);
      return _value(
        ref.read(chatRepositoryProvider).groupEvents(conversationId),
      );
    }, retry: _never);

/// "X changed the group picture" for a group: every member may read these
/// (inside their own readable window; the server decides), unlike
/// [groupEventsProvider]. An error here means no such lines, nothing more --
/// [chatTimelineProvider] reads it as empty.
final groupPictureEventsProvider = FutureProvider.autoDispose
    .family<List<GroupEvent>, String>((ref, conversationId) {
      ref.watch(currentUserIdProvider);
      return _value(
        ref.read(groupSettingsRepositoryProvider).pictureEvents(conversationId),
      );
    }, retry: _never);

/// A group's switches as the chat list last read them (the defaults for a
/// group the list does not hold). Watching this is what makes a screen follow
/// an admin's change, mine (optimistic) or someone else's (live).
final groupSettingsProvider = Provider.autoDispose
    .family<GroupSettings, String>(
      (ref, conversationId) => ref.watch(
        conversationListProvider.select(
          (s) =>
              (s.value ?? const <Conversation>[])
                  .where((c) => c.id == conversationId)
                  .firstOrNull
                  ?.settings ??
              const GroupSettings(),
        ),
      ),
    );

/// Groups an admin deleted while this account was signed in -- the one signal
/// a screen of such a group uses to leave itself (a chat merely missing from
/// the list can also mean a session change, which other code handles).
class DeletedGroups extends Notifier<Set<String>> {
  final _noticed = <String>{};

  @override
  Set<String> build() {
    ref.watch(currentUserIdProvider);
    _noticed.clear();
    return const {};
  }

  void add(String conversationId) {
    if (state.contains(conversationId)) return;
    state = {...state, conversationId};
  }

  /// True only the first time it is asked for [conversationId]: of the
  /// several screens that hear a deletion, exactly one shows the notice.
  bool claimNotice(String conversationId) => _noticed.add(conversationId);
}

final deletedGroupsProvider = NotifierProvider<DeletedGroups, Set<String>>(
  DeletedGroups.new,
);

/// Whether the signed-in member is a current admin of the group (false until
/// the roster is known). Only a hint for what to show: the server decides.
final amGroupAdminProvider = Provider.autoDispose.family<bool, String>((
  ref,
  conversationId,
) {
  final me = switch (ref.watch(sessionControllerProvider).value) {
    Allowed(:final member) => member.userId,
    _ => null,
  };
  final roster = ref.watch(groupRosterProvider(conversationId)).value;
  return roster?.any((m) => m.member.userId == me && !m.hasLeft && m.isAdmin) ??
      false;
});

/// The open conversation's messages merged with its group events, in order
/// -- what the message screen actually draws (see [buildTimeline]). Events
/// are asked for only when the open conversation is a group; a 1:1 never
/// has any, and skipping the call there saves a request that would only
/// ever come back empty.
final chatTimelineProvider = Provider.autoDispose<List<TimelineEntry>>((ref) {
  final conversationId = ref.watch(openConversationProvider);
  if (conversationId == null) return const [];
  final messages = ref.watch(messagesProvider).value ?? const <Message>[];
  final isGroup = ref.watch(
    conversationListProvider.select(
      (s) => (s.value ?? const <Conversation>[]).any(
        (c) => c.id == conversationId && c.isGroup,
      ),
    ),
  );
  if (!isGroup) return [for (final m in messages) MessageEntry(m)];
  final events =
      ref.watch(groupEventsProvider(conversationId)).value ??
      const <GroupEvent>[];
  final pictures =
      ref.watch(groupPictureEventsProvider(conversationId)).value ??
      const <GroupEvent>[];
  return buildTimeline(messages, [...events, ...pictures]);
});

final groupControllerProvider = Provider<GroupController>(GroupController.new);

/// Leaving, removing, adding and admins -- the actions a group's own page
/// offers. Each mutates the server through [ChatRepository] and then
/// invalidates exactly what it changed: the roster, the events, and (for
/// [leave], since the conversation's own hasLeft/preview may have moved)
/// the conversation list. State otherwise lives on the providers above, not
/// here: this class only orchestrates.
class GroupController {
  GroupController(this.ref);

  final Ref ref;

  /// Leaves [conversationId] (a group only; refused for a 1:1 or when the
  /// caller is no longer a current member). On success, anything still
  /// queued for it is dropped outright (there is nothing left to send into,
  /// and unlike a refused send it is not worth restoring to the draft) and
  /// its draft is cleared -- the same orchestration a removal discovers on
  /// its own, see [leftConversationGuardProvider]. The returned bool is
  /// whether something queued was actually dropped, for the caller's one
  /// notice ("Left the group" vs. "Left the group. N unsent message(s)
  /// were not sent.").
  Future<Result<bool>> leave(String conversationId) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .leaveGroup(conversationId);
    if (result case Err(:final failure)) return Err(failure);
    final dropped = _dropQueueAndDraft(conversationId);
    _invalidateGroup(conversationId);
    await ref.read(conversationListProvider.notifier).reloadQuietly();
    return Ok(dropped);
  }

  /// Removes [memberId] from [conversationId], admin-only, never the
  /// caller's own id (they leave instead -- the server refuses that call
  /// the same way [leave] would have to be used).
  Future<Result<void>> removeMember(
    String conversationId,
    String memberId,
  ) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .removeMember(conversationId, memberId);
    if (result is Ok) _invalidateGroup(conversationId);
    return result;
  }

  /// Adds each of [memberIds] to [conversationId], admin-only. [withHistory]
  /// is the "Show old messages?" choice offered alongside the picker.
  Future<Result<void>> addMembers(
    String conversationId,
    List<String> memberIds, {
    required bool withHistory,
  }) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .addMembers(conversationId, memberIds, withHistory: withHistory);
    if (result is Ok) _invalidateGroup(conversationId);
    return result;
  }

  /// Makes [memberId] an admin, or unmakes one, admin-only. The server
  /// refuses to leave the group with no admin at all.
  Future<Result<void>> setAdmin(
    String conversationId,
    String memberId, {
    required bool isAdmin,
  }) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .setAdmin(conversationId, memberId, isAdmin: isAdmin);
    if (result is Ok) {
      ref.invalidate(groupRosterProvider(conversationId));
    }
    return result;
  }

  bool _dropQueueAndDraft(String conversationId) {
    final dropped = ref
        .read(sendQueueProvider.notifier)
        .dropForLeft(conversationId);
    ref.read(draftsProvider.notifier).clear(conversationId);
    if (ref.read(openConversationProvider) == conversationId) {
      ref.read(replyingToProvider.notifier).clear();
      ref.read(editingProvider.notifier).clear();
    }
    return dropped;
  }

  /// Changes the group's switches. The new values show at once; when the
  /// server refuses (not an admin, or offline) only the switches this call
  /// changed go back to what they were and the failure is returned, so the
  /// screen can say why. Admin-only on the server.
  Future<Result<void>> setSettings(
    String conversationId, {
    bool? membersCanSetAvatar,
    bool? membersCanAdd,
    bool? newMembersSeeHistory,
  }) async {
    final list = ref.read(conversationListProvider.notifier);
    final before = list.settingsOf(conversationId);
    if (before == null) return const Err(DeniedFailure());
    list.applySettings(
      conversationId,
      before.copyWith(
        membersCanSetAvatar: membersCanSetAvatar,
        membersCanAdd: membersCanAdd,
        newMembersSeeHistory: newMembersSeeHistory,
      ),
    );
    final result = await ref
        .read(groupSettingsRepositoryProvider)
        .setSettings(
          conversationId,
          membersCanSetAvatar: membersCanSetAvatar,
          membersCanAdd: membersCanAdd,
          newMembersSeeHistory: newMembersSeeHistory,
        );
    if (result is Err && ref.mounted) {
      list.applySettings(
        conversationId,
        (list.settingsOf(conversationId) ?? before).copyWith(
          membersCanSetAvatar: membersCanSetAvatar == null
              ? null
              : before.membersCanSetAvatar,
          membersCanAdd: membersCanAdd == null ? null : before.membersCanAdd,
          newMembersSeeHistory: newMembersSeeHistory == null
              ? null
              : before.newMembersSeeHistory,
        ),
      );
    }
    return result;
  }

  /// Deletes [conversationId] for everyone, admin-only. On success anything
  /// queued for it and its draft are dropped, and the list is re-read (the
  /// group is gone from it).
  Future<Result<void>> deleteGroup(String conversationId) async {
    final result = await ref
        .read(groupSettingsRepositoryProvider)
        .deleteGroup(conversationId);
    if (result is Err) return result;
    ref.read(deletedGroupsProvider.notifier).add(conversationId);
    _dropQueueAndDraft(conversationId);
    await ref.read(conversationListProvider.notifier).reloadQuietly();
    return result;
  }

  void _invalidateGroup(String conversationId) {
    ref.invalidate(groupRosterProvider(conversationId));
    ref.invalidate(groupEventsProvider(conversationId));
    ref.invalidate(groupPictureEventsProvider(conversationId));
  }
}

/// Drops a conversation's queue and clears its draft the moment it is
/// discovered to be one the member has left or been removed from --
/// covers being removed by an admin while the app is running, found out
/// only on the next conversation-list refresh, with the same orchestration
/// [GroupController.leave] runs for an explicit leave. Deliberately silent
/// (no notice): [SisNotice] is for the result of something the member just
/// did, and being removed by someone else is not that -- the conversation's
/// own disabled write box ("You're no longer in this group") already says
/// why nothing more can be sent there.
///
/// Read once, for its side effect, from main.dart's provider overrides --
/// like [attachmentCacheOwnerProvider], this exists to be listened to for
/// the life of the app, not for its (unused) value.
final leftConversationGuardProvider = Provider<void>((ref) {
  ref.listen(conversationListProvider, (_, next) {
    final list = next.value;
    if (list == null) return;
    for (final c in list) {
      if (!c.hasLeft) continue;
      if (ref.read(sendQueueProvider.notifier).dropForLeft(c.id)) {
        ref.read(draftsProvider.notifier).clear(c.id);
      }
    }
  }, fireImmediately: true);
});

/// Keeps every member's chat list and open group page current when an admin
/// changes a group's settings or picture, adds people, or deletes the group:
/// the server nudges each member (a private per-user Realtime topic) and this
/// re-reads what changed. Read once, for its side effect, from SisApp, like
/// [leftConversationGuardProvider].
final groupChangesListenerProvider = Provider<void>((ref) {
  ref.watch(currentUserIdProvider);
  var alive = true;
  StreamSubscription<GroupChange>? sub;
  ref.onDispose(() {
    alive = false;
    unawaited(sub?.cancel());
  });
  unawaited(
    ref.read(groupSettingsRepositoryProvider).groupChanges().then((opened) {
      if (opened is! Ok<Stream<GroupChange>>) return;
      if (!alive) {
        unawaited(opened.value.listen((_) {}).cancel());
        return;
      }
      sub = opened.value.listen((change) {
        if (!ref.mounted) return;
        final id = change.conversationId;
        if (change.what == 'deleted') {
          ref.read(deletedGroupsProvider.notifier).add(id);
        }
        ref.invalidate(groupRosterProvider(id));
        ref.invalidate(groupEventsProvider(id));
        ref.invalidate(groupPictureEventsProvider(id));
        unawaited(ref.read(conversationListProvider.notifier).reloadQuietly());
      }, onError: (Object _) {});
    }),
  );
});
