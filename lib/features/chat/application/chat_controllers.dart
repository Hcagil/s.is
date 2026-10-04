import 'dart:async';
import 'dart:developer';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/member.dart';
import '../../auth/domain/session_state.dart';
import '../../notifications/application/push_controller.dart';
import '../../profile/application/profile_controller.dart';
import '../domain/attachment.dart';
import '../domain/chat_list_snapshot_store.dart';
import '../domain/chat_repository.dart';
import '../domain/conversation.dart';
import '../domain/contacts_repository.dart';
import '../domain/external_picker.dart';
import '../domain/gallery.dart';
import '../domain/links.dart';
import '../domain/message.dart';
import '../domain/picture_cropper.dart';
import '../domain/read_marks.dart';
import 'chat_drafts.dart';

final chatRepositoryProvider = Provider<ChatRepository>(
  (_) => throw UnimplementedError('override in main'),
);
final linkOpenerProvider = Provider<LinkOpener>(
  (_) => throw UnimplementedError('override in main'),
);

/// A short-lived URL for one attachment, kept while something shows it.
/// Signed for an hour; a screen open longer re-asks by being rebuilt.
final attachmentUrlProvider = FutureProvider.autoDispose.family<Uri, String>((
  ref,
  path,
) async {
  // A signed URL is issued to one account; a new account asks again.
  ref.watch(currentUserIdProvider);
  return switch (await ref.read(chatRepositoryProvider).attachmentUrl(path)) {
    Ok(:final value) => value,
    Err(:final failure) => throw failure,
  };
}, retry: (_, _) => null);

/// The phone's own photo library, for the attachment sheet's grid.
final galleryProvider = Provider<Gallery>(
  (_) => throw UnimplementedError('override in main'),
);

/// Picks photos through another app on the phone (Google Photos, the
/// maker's gallery, Files...), for the attachment sheet's "From an app"
/// entry.
final externalPickerProvider = Provider<ExternalPicker>(
  (_) => throw UnimplementedError('override in main'),
);

/// Crops a picture on the phone into the final square JPEG, for the crop
/// screen.
final pictureCropperProvider = Provider<PictureCropper>(
  (_) => throw UnimplementedError('override in main'),
);

/// Photos already on this phone. Cleared on sign-out.
final attachmentCacheProvider = Provider<AttachmentCache>(
  (_) => throw UnimplementedError('override in main'),
);

/// Runs [onEnd] on every settled answer that the session has ended --
/// signed out, or Denied (revoked or replaced on another device) -- with
/// `fireImmediately` so a cold start landing directly on either state is
/// caught too. Shared by [attachmentCacheOwnerProvider] and
/// [chatListSnapshotOwnerProvider], mirroring pushInboxOwnerProvider's reach.
void _onSessionEnd(Ref ref, Future<void> Function() onEnd) {
  ref.listen(sessionControllerProvider, (_, next) {
    switch (next.value) {
      case SignedOut() || Denied():
        unawaited(onEnd());
      case _:
    }
  }, fireImmediately: true);
}

/// Wipes the cache above as soon as the session is found to have ended --
/// signed out, or Denied (revoked or replaced on another device) -- so
/// nothing of a previous member's photos or pictures survives on this phone.
final attachmentCacheOwnerProvider = Provider<void>((ref) {
  _onSessionEnd(ref, () => ref.read(attachmentCacheProvider).clear());
});

/// Where the conversation list's last snapshot lives on the phone. The real
/// implementation is overridden in main.dart; data/ is the only layer
/// allowed to import path_provider.
final chatListSnapshotStoreProvider = Provider<ChatListSnapshotStore>(
  (_) => throw UnimplementedError('override in main'),
);

/// Erases the snapshot above as soon as the session is found to have ended,
/// mirroring [attachmentCacheOwnerProvider] exactly: same two states, same
/// fireImmediately, same reach (a cold start landing directly on SignedOut
/// or Denied included). A snapshot is per-owner-checked on read too (see
/// FileChatListSnapshotStore.load), so this is defence in depth, not the
/// only guard.
final chatListSnapshotOwnerProvider = Provider<void>((ref) {
  _onSessionEnd(ref, () => ref.read(chatListSnapshotStoreProvider).clear());
});

/// One attachment's bytes: from this phone when they are here, otherwise
/// downloaded once and kept. Replaces a signed URL per look, which fetched
/// the whole photo again every time.
final attachmentBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, path) async {
      // Per account, like every other read.
      ref.watch(currentUserIdProvider);
      return switch (await ref
          .read(chatRepositoryProvider)
          .attachmentBytes(path)) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };
    }, retry: (_, _) => null);

/// One profile's or group's picture: from this phone when it is here,
/// otherwise downloaded once and kept. A changed picture is a new storage
/// path (never an overwrite), so this is never stale.
final avatarBytesProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, path) async {
      ref.watch(currentUserIdProvider);
      return switch (await ref.read(chatRepositoryProvider).avatarBytes(path)) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };
    }, retry: (_, _) => null);

/// The conversation the message screen is showing, or null on the list screen.
///
/// [MessagesController] watches this, so opening a conversation rebuilds it and
/// closing one tears the Realtime subscription down. A family provider would
/// keep a controller per conversation alive; only one is ever on screen.
final openConversationProvider = NotifierProvider<OpenConversation, String?>(
  OpenConversation.new,
);

class OpenConversation extends Notifier<String?> {
  @override
  String? build() {
    // A new account starts with nothing open.
    ref.watch(currentUserIdProvider);
    return null;
  }

  void open(String conversationId) => state = conversationId;

  void close() => state = null;
}

/// Whether the app is on screen. False from AppLifecycleListener.onHide to
/// onShow (wired in app/sis_app.dart): a message that arrives meanwhile is
/// not marked read -- nobody saw it -- the resume catch-up
/// (resumeCatchUpProvider) marks it when the member returns.
final appVisibleProvider = NotifierProvider<AppVisible, bool>(AppVisible.new);

class AppVisible extends Notifier<bool> {
  @override
  bool build() => true;

  void set(bool visible) => state = visible;
}

/// Called when the app comes back to the foreground: the open chat and the
/// chat list fetch what they missed, and the open chat's notification goes
/// (its messages are on screen).
///
/// Those messages are also marked read: this phone's own Realtime listener
/// never heard what arrived while it was backgrounded (iOS suspends the
/// socket at once), so nothing else would tell the sender. The read marks
/// are joined again and re-read too, for the opposite case: a read that
/// happened while THIS phone was backgrounded.
final resumeCatchUpProvider = Provider<void Function()>((ref) {
  return () {
    // Nothing to catch up on before sign-in (and no repository to ask).
    if (ref.read(sessionControllerProvider).value is! Allowed) return;
    final open = ref.read(openConversationProvider);
    final list = ref.read(conversationListProvider.notifier);
    if (open == null) {
      unawaited(list.catchUp());
      return;
    }
    ref.read(messagesProvider.notifier).catchUp();
    unawaited(ref.read(pushSourceProvider).clearConversation(open));
    ref.invalidate(readMarksProvider);
    // Marked first, so the list's re-read sees the count already at zero.
    unawaited(list.markRead(open).then((_) => list.catchUp()));
  };
});

/// Riverpod 3 retries a failed build automatically, which leaves the provider
/// loading-with-an-error indefinitely instead of settling on [AsyncError] — an
/// endless spinner where ARCHITECTURE requires a reason on screen. Worse, a
/// DeniedFailure is a refusal that no amount of retrying can turn into data.
/// Retries are off; [refresh] is the explicit way back.
Duration? _never(int retryCount, Object error) => null;

/// True while the chat list on screen is the stored or last-read one because
/// a load failed; drives the small notice above the list (never an error box).
final conversationListStaleProvider =
    NotifierProvider<ConversationListStale, bool>(ConversationListStale.new);

class ConversationListStale extends Notifier<bool> {
  @override
  bool build() {
    // Another account never inherits the last one's notice.
    ref.watch(currentUserIdProvider);
    return false;
  }

  void set(bool stale) => state = stale;
}

final conversationListProvider =
    AsyncNotifierProvider<ConversationListController, List<Conversation>>(
      ConversationListController.new,
      retry: _never,
    );

/// The conversation list. Failures surface as [AsyncError] carrying the
/// [Failure], so the screen always has a reason to show.
class ConversationListController extends AsyncNotifier<List<Conversation>> {
  /// Batches a save after a live update so a burst of incoming messages
  /// costs one disk write, not one per message.
  Timer? _snapshotDebounce;

  /// Bumped by every build and every [catchUp], so a Realtime join that lands
  /// after a newer one started is dropped (ref.mounted cannot tell).
  int _gen = 0;

  /// The current all-conversations Realtime subscription.
  StreamSubscription<Message>? _live;

  /// Kept current by a Realtime subscription to every conversation the member
  /// belongs to. Subscribing happens BEFORE the first read and anything that
  /// arrives in between is buffered, the same way the message screen does it,
  /// so a message sent during the load is not lost.
  ///
  /// A subscription that cannot be established does not fail the list: the
  /// list still loads, and returning from a conversation refreshes it.
  @override
  Future<List<Conversation>> build() async {
    // Rebuilt from scratch for each account: never the last one's list.
    ref.watch(currentUserIdProvider);
    final ownerId = ref.read(currentUserIdProvider);
    final gen = ++_gen;
    ref.onDispose(() => unawaited(_live?.cancel()));
    // Riverpod 3 ALWAYS carries a previous value into a new AsyncLoading (or
    // a later AsyncError) via copyWithPrevious -- including one assigned
    // explicitly, right here, by this very build(): `state =
    // const AsyncLoading()` would still answer .value with the last owner's
    // rows, because copyWithPrevious merges with whatever state already held
    // (set by the framework itself before build() even starts, from the
    // previous owner's last settled list). AsyncData is the one exception --
    // AsyncData.copyWithPrevious always returns itself, ignoring what came
    // before -- so assigning a clean, empty AsyncData first launders the
    // slate, and the AsyncLoading assigned right after it only ever merges
    // with THAT (empty) value, never the old owner's. Both assignments land
    // before build()'s first await, so neither is ever observed on its own;
    // only the second is what the very first listener (an existing
    // subscriber, or a new one with fireImmediately) can ever see -- an
    // ordinary loading state whose .value is empty, not the previous owner's.
    // This is the one place every owner change routes through (the provider
    // lives for the app's whole run and only rebuilds when
    // currentUserIdProvider itself changes -- see its doc), so doing it here
    // makes it structurally impossible for a stale value to reach `_apply`,
    // `markRead`, `_saveCurrentIfData`, or an outside reader of `.value`
    // (conversation_list.dart, profile_pages.dart, ...): they all see an
    // AsyncLoading whose .value is the empty list (hasValue is true), not
    // the previous owner's rows, until THIS build's own settled data (the
    // disk cache below, or the server) lands.
    state = const AsyncData(<Conversation>[]);
    state = const AsyncLoading();
    // True for as long as THIS build is the current one. ref.mounted alone
    // cannot tell that apart from the Notifier being disposed outright: a
    // rebuild (e.g. an account change) reuses the same Notifier, so
    // ref.mounted stays true for a build already replaced by a newer one.
    // Registered synchronously, before the cache read below, so it is set
    // the moment this build is replaced OR the Notifier is disposed -- and
    // also guards the cache-restore state assignment right below.
    var alive = true;
    ref.onDispose(() => alive = false);
    // The store provider is unoverridden in most tests (it throws
    // UnimplementedError the moment it's read, not just on a failed disk
    // op), so this must be guarded the same as any other best-effort read.
    List<Conversation>? cached;
    if (ownerId != null) {
      try {
        cached = await ref.read(chatListSnapshotStoreProvider).load(ownerId);
      } catch (_) {
        cached = null;
      }
    }
    if (cached != null && alive && ref.mounted) state = AsyncData(cached);
    final buffered = <Message>[];
    var loaded = false;
    ref.onDispose(() => _snapshotDebounce?.cancel());
    // The Realtime join can take up to 15s and must never gate the list: it
    // starts alongside the fetch below instead of being awaited first.
    // Nothing can arrive before the join itself completes, and the
    // StreamController buffers anything that lands before `.listen` runs
    // here (see _inserts), so whichever of the join or the load finishes
    // first, nothing sent during the race is lost.
    unawaited(
      ref
          .read(chatRepositoryProvider)
          .incomingAll()
          .then((opened) {
            if (opened case Ok(:final value)) {
              if (!alive || gen != _gen) {
                // This build was replaced or disposed while the join was
                // still out: listen only long enough to cancel, which tears
                // the channel down through the same onCancel -> leaveChannel
                // path a normal cancel uses, rather than leaving a live
                // subscription nothing owns.
                unawaited(value.listen((_) {}).cancel());
                return;
              }
              final sub = value.listen(
                (message) {
                  if (!loaded) {
                    buffered.add(message);
                  } else {
                    _apply(message);
                  }
                },
                // A dropped subscription only stops live updates; the
                // re-read on returning from a conversation still keeps the
                // list current.
                onError: (Object _) {},
              );
              _live = sub;
              ref.onDispose(sub.cancel);
            }
          })
          .catchError((Object e, StackTrace st) {
            // A join that throws before it can even answer Err (e.g.
            // _client.channel() itself) only costs the live part, same as
            // an Err from incomingAll() and a dropped subscription later --
            // the list still loads and refresh() still works.
            log('$e', name: 'sis.chat', error: e, stackTrace: st);
          }),
    );
    List<Conversation> list;
    try {
      list = await _load();
      loaded = true;
      var unknown = false;
      for (final message in buffered) {
        if (message.isDeleted || message.editedAt != null) {
          unknown = true; // a deletion or edit during the load: read again
          continue;
        }
        final next = _withMessage(list, message);
        if (next == null) {
          unknown = true;
        } else {
          list = next;
        }
      }
      // A buffered message for a conversation the first read did not contain
      // means one was started during the load: read again rather than drop it.
      if (unknown) list = await _load();
    } catch (e) {
      // A stored list already shown stays on every load error but a refusal
      // (DeniedFailure; the session controller handles a revoked member):
      // the member's own data beats an error box, and a small notice says it
      // is old.
      if (cached == null || e is DeniedFailure) rethrow;
      loaded = true;
      list = cached;
      _setStale(true);
      return list;
    }
    if (ownerId != null && alive) _saveSnapshot(ownerId, list);
    _setStale(false);
    return list;
  }

  /// Fire-and-forget: the store itself never throws once read (see
  /// ChatListSnapshotStore's contract), but reading the provider does, when
  /// nothing overrides it (most tests) -- guarded the same as [build]'s read.
  void _saveSnapshot(String ownerId, List<Conversation> conversations) {
    try {
      unawaited(
        ref.read(chatListSnapshotStoreProvider).save(ownerId, conversations),
      );
    } catch (_) {
      // No store configured: nothing to save to.
    }
  }

  /// Moves [message] into its conversation's preview. A message for a
  /// conversation the list has never seen means someone started one with
  /// this member, so the list is re-read rather than guessed at.
  void _apply(Message message) {
    final current = state.value;
    if (current == null) return;
    // A deletion can change which message a conversation previews, and the
    // list does not hold the one before it: read again.
    if (message.isDeleted) {
      reloadQuietly();
      return;
    }
    if (message.editedAt != null) {
      final index = current.indexWhere((c) => c.id == message.conversationId);
      // Only when the edited message is still the previewed one -- an edit
      // to an older message further up the conversation changes nothing
      // shown in the list.
      final previewedAt = index >= 0 ? current[index].lastMessageAt : null;
      if (index >= 0 &&
          (previewedAt?.isAtSameMomentAs(message.createdAt) ?? false)) {
        state = AsyncData([
          for (var i = 0; i < current.length; i++)
            if (i == index) current[i].withPreview(message) else current[i],
        ]);
        _scheduleSnapshotSave();
      }
      return;
    }
    final next = _withMessage(current, message);
    if (next == null) {
      reloadQuietly();
    } else {
      state = AsyncData(next);
      _scheduleSnapshotSave();
    }
  }

  /// [list] with [message] as its conversation's preview, newest first; null
  /// when the conversation is not in [list]. An older message never replaces
  /// a newer preview, so a late or repeated delivery is harmless -- and is
  /// never counted as unread twice.
  List<Conversation>? _withMessage(List<Conversation> list, Message message) {
    final index = list.indexWhere((c) => c.id == message.conversationId);
    if (index < 0) return null;
    final existing = list[index];
    final me = switch (ref.read(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    // A sender the list does not know yet (someone added to this group since
    // the list was read) cannot be named or coloured: null makes the caller
    // read the list again, as for an unknown conversation.
    if (existing.isGroup &&
        !existing.isSystem &&
        message.senderId != me &&
        !existing.senders.containsKey(message.senderId)) {
      return null;
    }
    final at = existing.lastMessageAt;
    // Not newer than the current preview -- a late delivery, or the same
    // message delivered twice -- leaves the list exactly as it was. Using
    // "older" here instead would let a duplicate move its conversation above
    // one with a genuinely newer message.
    if (at != null && !message.createdAt.isAfter(at)) return list;
    final updated = [...list]..removeAt(index);
    // Unread: someone else's message, in a conversation not on screen.
    final counts =
        message.senderId != me &&
        ref.read(openConversationProvider) != message.conversationId;
    return [existing.withPreview(message, counts: counts), ...updated];
  }

  /// Marks [conversationId] read on the server, then clears its count here.
  /// A failure leaves the count as it was: better a stale badge than a
  /// conversation that looks read and is not.
  ///
  /// Skips the local update (and therefore the debounced save) when state is
  /// still loading -- i.e. carrying over a value from a previous build/owner.
  Future<void> markRead(String conversationId) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .markRead(conversationId);
    // Checked before touching state: the list can be disposed while the call
    // is in flight, and reading state then throws.
    if (result is! Ok || !ref.mounted || state.isLoading) return;
    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final c in current) c.id == conversationId ? c.read() : c,
    ]);
    _scheduleSnapshotSave();
  }

  Future<List<Conversation>> _load() async {
    return switch (await ref.read(chatRepositoryProvider).conversations()) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
  }

  /// Sets the stale notice; a no-op after dispose.
  void _setStale(bool stale) {
    if (ref.mounted) {
      ref.read(conversationListStaleProvider.notifier).set(stale);
    }
  }

  Future<void> refresh() async {
    final ownerId = ref.read(currentUserIdProvider);
    state = const AsyncLoading();
    final next = await AsyncValue.guard(_load);
    if (!ref.mounted) return;
    if (ref.read(currentUserIdProvider) != ownerId) return;
    state = next;
    // An explicit refresh still reports its failure (the error box), so the
    // saved-list notice has nothing to say here.
    _setStale(false);
    _saveCurrentIfData();
  }

  /// The app is visible again after being backgrounded, where the Realtime
  /// connection dies and nothing sent meanwhile is delivered: re-read the
  /// list at once, then join again and re-read once more to close the gap
  /// the join leaves. Skipped while a build is still loading (it is fresh).
  Future<void> catchUp() async {
    if (state.isLoading || !ref.mounted) return;
    final gen = ++_gen;
    final old = _live;
    _live = null;
    if (old != null) unawaited(old.cancel());
    await reloadQuietly();
    final opened = await ref.read(chatRepositoryProvider).incomingAll();
    if (opened is! Ok<Stream<Message>>) return;
    if (gen != _gen || !ref.mounted) {
      unawaited(opened.value.listen((_) {}).cancel());
      return;
    }
    _live = opened.value.listen(_apply, onError: (Object _) {});
    // ponytail: a message inserted during this last read can be missed; the
    // next resume or returning from a chat reads again.
    await reloadQuietly();
  }

  /// Re-reads without showing a spinner: the list on screen stays while the
  /// new one loads. A failed background re-read keeps the list as it was
  /// rather than replacing something correct with an error the member did
  /// not ask for; the explicit [refresh] still reports failures.
  Future<void> reloadQuietly() async {
    final ownerId = ref.read(currentUserIdProvider);
    final next = await AsyncValue.guard(_load);
    if (!ref.mounted) return;
    if (ref.read(currentUserIdProvider) != ownerId) return;
    if (next is AsyncData<List<Conversation>>) state = next;
    _setStale(next is AsyncError);
    _saveCurrentIfData();
  }

  /// A full load just finished (explicit [refresh] or a quiet re-read):
  /// saved right away, unlike a single live update, which is debounced by
  /// [_scheduleSnapshotSave] instead.
  ///
  /// Saves only when the session is settled (Allowed) AND this build's state
  /// is settled (AsyncData with isLoading=false), not carrying over a value
  /// from a previous build/owner.
  void _saveCurrentIfData() {
    if (ref.read(sessionControllerProvider).value is! Allowed) return;
    final ownerId = ref.read(currentUserIdProvider);
    final current = state;
    if (ownerId != null &&
        current is AsyncData<List<Conversation>> &&
        !current.isLoading) {
      _saveSnapshot(ownerId, current.value);
    }
  }

  /// Batches a save after a live update so a burst of incoming messages
  /// costs one disk write, not one per message. Checks the store is
  /// actually configured BEFORE scheduling: with nothing to save to (most
  /// tests, which never override [chatListSnapshotStoreProvider]) this must
  /// not leave a bare Timer running past the caller's own lifetime.
  void _scheduleSnapshotSave() {
    try {
      ref.read(chatListSnapshotStoreProvider);
    } catch (_) {
      return;
    }
    _snapshotDebounce?.cancel();
    _snapshotDebounce = Timer(const Duration(seconds: 2), _saveCurrentIfData);
  }

  /// Opens the 1:1 conversation with [otherUserId], creating it if needed.
  Future<Result<String>> startWith(String otherUserId) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .startDirectConversation(otherUserId);
    if (result is Ok<String>) {
      await refresh();
    }
    return result;
  }

  /// Creates a group and shows it in the list.
  Future<Result<String>> startGroup({
    required String title,
    required List<String> memberIds,
  }) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .startGroupConversation(title: title, memberIds: memberIds);
    if (result is Ok<String>) {
      await refresh();
    }
    return result;
  }

  /// Sets or clears [conversationId]'s picture; any member may call this.
  /// Re-reads the list quietly on success, same as [markRead].
  Future<Result<void>> setGroupAvatar(
    String conversationId,
    PickedImage? image,
  ) async {
    final previous = (state.value ?? const <Conversation>[])
        .where((c) => c.id == conversationId)
        .firstOrNull
        ?.avatarPath;
    final result = await ref
        .read(chatRepositoryProvider)
        .setGroupAvatar(conversationId, image, previousPath: previous);
    if (result is Ok && ref.mounted) {
      await reloadQuietly();
    }
    return result;
  }
}

/// "Your people": your contacts, plus whoever you already share a
/// conversation with. Row-level security computes exactly this set --
/// anyone else is reachable only through ContactsRepository.findByTag.
final yourPeopleProvider = FutureProvider<List<Member>>((ref) async {
  // Depends on who "you" are.
  ref.watch(currentUserIdProvider);
  return switch (await ref.read(chatRepositoryProvider).members()) {
    Ok(:final value) => value,
    Err(:final failure) => throw failure,
  };
}, retry: _never);

final contactsRepositoryProvider = Provider<ContactsRepository>(
  (_) => throw UnimplementedError('override in main'),
);

/// The caller's own contacts (add/remove) and the exact-tag lookup, as one
/// state machine: `state` is always the current set of contact user ids,
/// kept in sync with every add/remove so a screen watching it updates at
/// once, without waiting for a re-fetch.
final contactsControllerProvider =
    AsyncNotifierProvider.autoDispose<ContactsController, Set<String>>(
      ContactsController.new,
      retry: _never,
    );

class ContactsController extends AsyncNotifier<Set<String>> {
  @override
  Future<Set<String>> build() async {
    ref.watch(currentUserIdProvider);
    return switch (await ref.read(contactsRepositoryProvider).ids()) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
  }

  /// The one allowlisted member with this exact tag, or null. See
  /// [ContactsRepository.findByTag] for the rate-limit error shape.
  Future<Result<Member?>> findByTag(String tag) =>
      ref.read(contactsRepositoryProvider).findByTag(tag);

  Future<Result<void>> add(String userId) async {
    final result = await ref.read(contactsRepositoryProvider).add(userId);
    if (result is Ok && ref.mounted) {
      state = AsyncData({...(state.value ?? const <String>{}), userId});
      // A newly added contact belongs in "your people" too.
      ref.invalidate(yourPeopleProvider);
    }
    return result;
  }

  Future<Result<void>> remove(String userId) async {
    final result = await ref.read(contactsRepositoryProvider).remove(userId);
    if (result is Ok && ref.mounted) {
      state = AsyncData({...(state.value ?? const <String>{})}..remove(userId));
      ref.invalidate(yourPeopleProvider);
    }
    return result;
  }
}

final messagesProvider =
    AsyncNotifierProvider<MessagesController, List<Message>>(
      MessagesController.new,
      retry: _never,
    );

/// True while an older page of the open conversation is being read: the
/// screen shows a small loader at the top of the list meanwhile.
final olderLoadingProvider = NotifierProvider<OlderLoading, bool>(
  OlderLoading.new,
);

class OlderLoading extends Notifier<bool> {
  @override
  bool build() {
    ref.watch(openConversationProvider);
    return false;
  }

  void set(bool loading) => state = loading;
}

/// Messages of the open conversation, oldest first.
///
/// The initial read and the Realtime stream are merged by message id.
/// Sending a text message (or a photo, since v0.9) is optimistic: a pending
/// bubble shows the moment [MessagesController.send] is called, before the
/// server has answered, and several sent in quick succession queue behind
/// one another so the server sees them -- and times them -- in the order
/// they were typed (see [MessagesController.send] and
/// [MessagesController._drain]). The server's own row then replaces the
/// pending bubble in place, whichever answer arrives first -- the POST
/// response or the Realtime echo of the same insert -- so the sender's own
/// message appears exactly once, never twice.
class MessagesController extends AsyncNotifier<List<Message>> {
  /// Whether the shown list is a [jumpToAround] snapshot rather than the
  /// live, newest window.
  bool _jumped = false;

  /// Counts this member's own optimistic deletes and hides, so a background
  /// re-read that began before one cannot undo it (see _verify).
  int _ownEdits = 0;

  /// True while [jumpToAround] has replaced the shown list with an old
  /// window; false once live (including before any jump at all).
  bool get isJumped => _jumped;

  /// Set by [returnToLive]: the next build carries nothing over from the
  /// jumped window (it is not contiguous with the live page).
  bool _fromJump = false;

  /// The anchor id of the most recent [jumpToAround] call -- an answer for
  /// any earlier one is dropped, even if it arrives later.
  String? _requestedAnchorId;

  /// The conversation the current state belongs to. Riverpod 3 always carries
  /// the previous value into a reload, so a rebuild for a different chat would
  /// otherwise answer `.value` with the chat just left.
  String? _stateFor;

  /// Bumped by every build: an answer that started under an older build is
  /// dropped.
  int _epoch = 0;

  /// True once the oldest message of the conversation is loaded (a read that
  /// came back shorter than [messagePageSize]).
  bool _noOlder = false;
  bool _loadingOlder = false;
  bool _loadingNewer = false;
  int _catchUpRetries = 0;
  static const _maxCatchUpRetries = 5;
  DateTime _verifiedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// The live list shown just before the first [jumpToAround] of a jump run:
  /// [returnToLive] shows it at once, without waiting for the network.
  List<Message>? _liveBeforeJump;

  /// Photo messages whose preview was already asked for in this build, so a
  /// message that has none is not asked again and again.
  final _previewAsked = <String>{};

  /// Whether scrolling up may still find older messages.
  bool get hasOlder => !_noOlder;

  /// The newest messages of chats left this run, shown at once when one is
  /// opened again while the read is out. Cleared on an account change.
  final _memory = <String, List<Message>>{};
  String? _memoryOwner;

  void _remember(String id, List<Message>? list) {
    if (list == null) return;
    final kept = [
      for (final m in list)
        if (!m.isPending) m,
    ];
    _memory.remove(id);
    if (kept.isEmpty) return;
    // Only the newest page is kept: that is what the next open reads first.
    _memory[id] = kept.length > messagePageSize
        ? kept.sublist(kept.length - messagePageSize)
        : kept;
    if (_memory.length > 8) _memory.remove(_memory.keys.first);
  }

  @override
  Future<List<Message>> build() async {
    final owner = ref.watch(currentUserIdProvider);
    if (owner != _memoryOwner) {
      _memory.clear();
      _memoryOwner = owner;
      _stateFor = null;
    }
    final wasJumped = _jumped;
    _jumped = false;
    final conversationId = ref.watch(openConversationProvider);
    if (_stateFor != conversationId) {
      final left = _stateFor;
      if (left != null && !wasJumped) _remember(left, state.value);
      _stateFor = conversationId;
      // Launder the carried value, as ConversationListController.build does:
      // the AsyncData is replaced by AsyncLoading before the first await, so
      // only a loading state is ever observed -- never the last chat's
      // messages. What it holds is this chat's own remembered list (empty
      // when none), which the screen shows while the read is out. (A
      // same-chat catchUp keeps its value on purpose.)
      state = AsyncData(_memory[conversationId] ?? const <Message>[]);
      state = const AsyncLoading();
    }
    if (conversationId == null) return const [];
    _epoch++;
    if (_loadingOlder) {
      // The page in flight belongs to the replaced build, which will not clear
      // the loader; a provider may not be written during build, so a turn later.
      Future.microtask(() {
        if (ref.mounted) ref.read(olderLoadingProvider.notifier).set(false);
      });
    }
    _loadingOlder = false;
    _loadingNewer = false;
    _liveBeforeJump = null;
    _noOlder = false;
    _previewAsked.clear();
    // What this chat already shows (its remembered newest page, or what a
    // catch-up rebuild keeps): previews and older rows outlive the new read.
    final fromJump = wasJumped || _fromJump;
    _fromJump = false;
    // A jumped window is not contiguous with the live page: none of it is
    // carried over (its previews are read again).
    final shownBefore = fromJump
        ? const <Message>[]
        : (state.value ?? const <Message>[]);

    final repo = ref.read(chatRepositoryProvider);
    final buffered = <Message>[];
    var loaded = false;
    StreamSubscription<Message>? sub;
    ref.onDispose(() => unawaited(sub?.cancel()));
    // True while THIS build is current: ref.mounted stays true for a build
    // already replaced by a newer one (a chat switch), onDispose fires for both.
    var alive = true;
    ref.onDispose(() => alive = false);
    void onMessage(Message message) {
      // Strictly this chat's: a row for another conversation is never shown.
      if (message.conversationId != conversationId) return;
      if (!loaded) {
        buffered.add(message);
        return;
      }
      if (message.isDeleted) {
        _deleted(message);
        return;
      }
      if (message.editedAt != null) {
        _edited(message);
        return;
      }
      _append(message);
      // Open on screen means read; tell the server so the count stays zero.
      // Only while the app is visible: one that lands while it is hidden is
      // marked by the resume catch-up, when the member actually returns.
      if (!message.isFrom(_me ?? '') && ref.read(appVisibleProvider)) {
        ref.read(conversationListProvider.notifier).markRead(conversationId);
      }
    }

    // Pending sends: queued, in flight, or waiting out a network retry in
    // SendQueueController, which lives independently of this screen. This
    // conversation's list starts with whatever it already holds (below) and
    // is kept current as the queue changes -- see _onQueueChanged -- so a
    // chat reopened mid-send, or opened for the first time while offline
    // sends are still queued, shows them rather than dropping them.
    ref.listen(
      sendQueueProvider.select((m) => m[conversationId] ?? const <Message>[]),
      _onQueueChanged,
    );

    // The join and the read run together, so opening costs the longer of the
    // two, not both. The stream is listened to the moment the join answers;
    // whatever it delivers before the read lands is buffered and merged by
    // id. The read may have been answered before the join took effect on the
    // server, so _verify reads once more after the first paint.
    final joining = repo.incoming(conversationId).then((opened) {
      if (opened case Ok(:final value)) {
        if (alive && ref.mounted) {
          sub = value.listen(onMessage);
        } else {
          unawaited(value.listen((_) {}).cancel());
        }
      }
      return opened;
    });
    final (joined, read) = await (joining, repo.messages(conversationId)).wait;
    if (!alive) return const []; // replaced or closed mid-open: drop it all
    // A catch-up that cannot reach the server (resume while offline) keeps
    // the list on screen and tries again a little later; only a first open,
    // with nothing to show, is an error.
    final failed = switch ((joined, read)) {
      (Err(:final failure), _) => failure,
      (_, Err(:final failure)) => failure,
      _ => null,
    };
    if (failed != null) {
      if (shownBefore.isEmpty || _catchUpRetries >= _maxCatchUpRetries) {
        throw failed;
      }
      _catchUpRetries++;
      unawaited(
        Future<void>.delayed(const Duration(seconds: 5), () {
          if (alive && ref.mounted) ref.invalidateSelf();
        }),
      );
      return shownBefore;
    }
    _catchUpRetries = 0;

    switch (read) {
      case Err():
        throw StateError('unreachable: read failure handled above');
      case Ok(:final value):
        loaded = true;
        final known = {
          for (final m in shownBefore)
            if (m.attachmentPreview != null) m.id: m.attachmentPreview!,
        };
        final merged = [
          for (final m in value)
            m.attachmentPreview == null && known[m.id] != null
                ? m.withPreview(known[m.id])
                : m,
        ];
        _noOlder = value.length < messagePageSize;
        // Older rows already loaded stay (a scroll position deep in history
        // must not be cut off by a catch-up) -- but only when the new page
        // overlaps them, so the history never has a gap.
        final inPage = {for (final m in value) m.id};
        if (value.isNotEmpty && shownBefore.any((m) => inPage.contains(m.id))) {
          merged.addAll([
            for (final m in shownBefore)
              if (!m.isPending &&
                  !inPage.contains(m.id) &&
                  m.createdAt.isBefore(value.first.createdAt))
                m,
          ]);
        }
        for (final message in buffered) {
          if (message.conversationId != conversationId) continue;
          final i = merged.indexWhere((m) => m.id == message.id);
          if (i < 0) {
            // An edit or delete of a row older than the page is not for this
            // list: ignored, never added out of place.
            if (value.isNotEmpty &&
                message.createdAt.isBefore(value.first.createdAt)) {
              continue;
            }
            merged.add(message);
          } else if (message.isDeleted || message.editedAt != null) {
            merged[i] = message;
          }
        }
        merged.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        // Vanished before this screen opened: as if never sent. One that
        // vanishes while open stays long enough to animate away.
        final shown = [
          for (final m in merged)
            if (m.deletion != MessageDeletion.vanished) m,
        ];
        final pending = ref.read(sendQueueProvider)[conversationId] ?? const [];
        // A later turn, so the list below is already the state when it runs.
        final edits = _ownEdits;
        // Previews (one batched read) start at once, beside the verify read;
        // verify may add rows, so they are looked at again after it.
        unawaited(
          Future(() {
            unawaited(_fillPreviews(conversationId, () => alive));
            return _verify(
              conversationId,
              edits,
              () => alive,
            ).then((_) => _fillPreviews(conversationId, () => alive));
          }),
        );
        // My own photos still in the air (not in the send queue, which holds
        // text only) stay across this re-read, e.g. the one returnToLive
        // starts; a stored copy of one that already landed replaces it.
        final photos = [
          for (final m in state.value ?? const <Message>[])
            if (m.conversationId == conversationId &&
                m.localImage != null &&
                m.attachmentPath == null &&
                !m.sending &&
                !shown.any((s) => s.id == m.id || m.isPendingOf(s)))
              m,
        ];
        return [
          ...shown,
          for (final p in pending)
            if (!shown.any((m) => m.id == p.id)) p,
          ...photos,
        ];
    }
  }

  /// The app is visible again after being backgrounded (or a notification
  /// for this chat was tapped): Realtime died meanwhile and nothing sent
  /// since was delivered, so read the chat again with a fresh subscription
  /// -- build()'s own read, with a fresh subscription. Not while a build is
  /// loading (it is fresh) or a search jump is on screen.
  void catchUp() {
    if (_jumped || state.isLoading) return;
    ref.invalidateSelf();
  }

  /// The member is back at the newest message: a Realtime row missed while the
  /// connection was down (no resume event) is read in by _verify. At most once
  /// per 20 s, never on a search window, never while a build is loading.
  void verifyNewest() {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null ||
        _jumped ||
        state.isLoading ||
        state.hasError ||
        (state.value?.isEmpty ?? true)) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_verifiedAt) < const Duration(seconds: 20)) return;
    _verifiedAt = now;
    final epoch = _epoch;
    bool alive() => ref.mounted && epoch == _epoch;
    unawaited(
      _verify(
        conversationId,
        _ownEdits,
        alive,
      ).then((_) => _fillPreviews(conversationId, alive)),
    );
  }

  /// The first read leaves photo previews out so the first paint never waits
  /// on them; one batched read (the photo messages without one, at most a
  /// page) brings them in right after. One request rather than one per
  /// bubble: a single round trip, and the rows are known already. A failure is
  /// silent -- the photo itself still loads and replaces the blur.
  Future<void> _fillPreviews(
    String conversationId,
    bool Function() alive,
  ) async {
    if (!alive() || !ref.mounted) return;
    final current = state.value;
    if (current == null) return;
    final ids = [
      for (final m in current)
        if (m.attachmentPath != null &&
            m.attachmentPreview == null &&
            _previewAsked.add(m.id))
          m.id,
    ];
    if (ids.isEmpty) return;
    final result = await ref
        .read(chatRepositoryProvider)
        .attachmentPreviews(ids);
    if (!alive() || !ref.mounted) return;
    if (ref.read(openConversationProvider) != conversationId) return;
    final now = state.value;
    if (result is! Ok<Map<String, Uint8List>> || now == null) return;
    final found = result.value;
    if (found.isEmpty) return;
    state = AsyncData([
      for (final m in now)
        m.attachmentPreview == null && found[m.id] != null
            ? m.withPreview(found[m.id])
            : m,
    ]);
  }

  /// Reads the page before the oldest shown message and puts it above, by id.
  /// The screen lists newest-first from the bottom, so rows added past the top
  /// do not move what the member is looking at. Reuses
  /// [ChatRepository.messagesAround] (the oldest shown message as anchor; its
  /// newer half is already shown and is dropped by id). One read at a time;
  /// an answer for a chat that was left or rebuilt meanwhile is dropped, and
  /// a failure is silent -- the next scroll tries again.
  Future<void> loadOlder() async {
    final conversationId = ref.read(openConversationProvider);
    final current = state.value;
    if (conversationId == null ||
        current == null ||
        state.isLoading ||
        _noOlder ||
        _loadingOlder) {
      return;
    }
    final oldest = current.where((m) => !m.isPending).firstOrNull;
    if (oldest == null) return;
    final epoch = _epoch;
    _loadingOlder = true;
    ref.read(olderLoadingProvider.notifier).set(true);
    final result = await ref
        .read(chatRepositoryProvider)
        .messagesAround(conversationId, oldest);
    if (!ref.mounted) return;
    if (epoch != _epoch) return; // rebuilt meanwhile: the new build owns this
    ref.read(olderLoadingProvider.notifier).set(false);
    _loadingOlder = false;
    final now = state.value;
    if (result is! Ok<List<Message>> || now == null) return;
    final shown = {for (final m in now) m.id};
    final fresh = [
      for (final m in result.value)
        if (!shown.contains(m.id) && !m.createdAt.isAfter(oldest.createdAt)) m,
    ];
    // Counted before dropping vanished rows: a short page is the real start.
    if (fresh.length < messagePageSize) _noOlder = true;
    final older = [
      for (final m in fresh)
        if (m.deletion != MessageDeletion.vanished) m,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (older.isEmpty) return;
    state = AsyncData([...older, ...now]);
  }

  /// The mirror of [loadOlder] for a jumped window: reads the page after the
  /// newest shown message and appends it, so scrolling down always reaches the
  /// live end. A page shorter than [messagePageSize] is the live end: the
  /// window becomes the live list again (Realtime appends resume) and one
  /// verify read closes any gap. No-op unless [isJumped]; one read at a time;
  /// a failure is silent, the next scroll tries again.
  Future<void> loadNewer() async {
    final conversationId = ref.read(openConversationProvider);
    final current = state.value;
    if (!_jumped ||
        conversationId == null ||
        current == null ||
        state.isLoading ||
        _loadingNewer) {
      return;
    }
    final newest = current.where((m) => !m.isPending).lastOrNull;
    if (newest == null) return;
    final epoch = _epoch;
    _loadingNewer = true;
    final result = await ref
        .read(chatRepositoryProvider)
        .messagesAround(conversationId, newest);
    if (!ref.mounted || epoch != _epoch) return;
    _loadingNewer = false;
    final now = state.value;
    if (!_jumped || result is! Ok<List<Message>> || now == null) return;
    final shown = {for (final m in now) m.id};
    final fresh = [
      for (final m in result.value)
        if (!shown.contains(m.id) && !m.createdAt.isBefore(newest.createdAt)) m,
    ];
    // Counted before dropping vanished rows: a short page is the live end.
    final live = fresh.length < messagePageSize;
    final newer = [
      for (final m in fresh)
        if (m.deletion != MessageDeletion.vanished) m,
    ]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    if (live) {
      _jumped = false;
      _liveBeforeJump = null;
    }
    if (newer.isNotEmpty || live) state = AsyncData([...now, ...newer]);
    if (live) {
      final edits = _ownEdits;
      unawaited(
        _verify(conversationId, edits, () => ref.mounted && epoch == _epoch),
      );
    }
  }

  /// The first read can be served before the join took effect on the server:
  /// a message sent in between is in neither it nor the stream. A second read,
  /// after both, closes that window. Merged by id, so nothing is shown twice;
  /// an edit or delete that landed in the window replaces the old row.
  Future<void> _verify(
    String conversationId,
    int edits,
    bool Function() alive,
  ) async {
    if (!alive() || !ref.mounted) return;
    final result = await ref
        .read(chatRepositoryProvider)
        .messages(conversationId);
    // A delete or hide made meanwhile is not on the server yet: this read
    // would put the row back.
    if (!alive() || !ref.mounted || _jumped || edits != _ownEdits) return;
    if (ref.read(openConversationProvider) != conversationId) return;
    final current = state.value;
    if (result is! Ok<List<Message>> || current == null) return;
    var next = current;
    for (final m in result.value) {
      if (m.deletion == MessageDeletion.vanished) continue;
      final i = next.indexWhere((x) => x.id == m.id);
      if (i < 0) {
        next = [...next, m];
      } else if (_newer(m, next[i])) {
        final kept = next[i].attachmentPreview;
        next = [...next]
          ..[i] = m.attachmentPreview == null && kept != null
              ? m.withPreview(kept)
              : m;
      }
    }
    if (identical(next, current)) return;
    state = AsyncData(
      [...next]..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
    );
  }

  /// Whether [read] is a later state of [shown] than what is on screen: a
  /// delete, or a later edit. Never the other way round -- a read that began
  /// before a live event must not undo it.
  static bool _newer(Message read, Message shown) {
    if (shown.isDeleted) return false;
    if (read.isDeleted) return true;
    final at = read.editedAt;
    final was = shown.editedAt;
    return at != null && (was == null || at.isAfter(was));
  }

  /// Reconciles this conversation's shown list with [SendQueueController]'s
  /// pending list for it: a new id is upserted in place (added if unseen,
  /// replacing an existing entry with the same id -- covers both a brand
  /// new pending bubble and the resolved row published just before the
  /// queue drops it, see SendQueueController._drain); an id that leaves the
  /// queue is removed from here only while still pending -- once resolved
  /// it was already upserted to the final, non-pending message above, and
  /// must stay.
  void _onQueueChanged(List<Message>? previous, List<Message> next) {
    // Sending from a jumped window goes back to live first, so the sent
    // message shows at the bottom without a gap.
    if (_jumped && next.isNotEmpty) returnToLive();
    final current = state.value;
    if (current == null) return;
    var list = current;
    for (final m in next) {
      final i = list.indexWhere((x) => x.id == m.id);
      if (i < 0) {
        list = [...list, m];
      } else if (!identical(list[i], m)) {
        list = [...list]..[i] = m;
      }
    }
    final nextIds = {for (final m in next) m.id};
    for (final m in previous ?? const <Message>[]) {
      if (nextIds.contains(m.id)) continue;
      final i = list.indexWhere((x) => x.id == m.id);
      if (i >= 0 && list[i].isPending) {
        list = [...list]..removeAt(i);
      }
    }
    if (!identical(list, current)) state = AsyncData(list);
  }

  String? get _me => switch (ref.read(sessionControllerProvider).value) {
    Allowed(:final member) => member.userId,
    _ => null,
  };

  /// A message deleted for everyone replaces its old self, and its photo
  /// leaves this phone's cache.
  void _deleted(Message message) {
    final current = state.value;
    if (current == null) return;
    final i = current.indexWhere((m) => m.id == message.id);
    if (i < 0) return;
    final old = current[i];
    final path = old.attachmentPath;
    if (path != null) unawaited(ref.read(attachmentCacheProvider).remove(path));
    // A vanishing message keeps its text for the moment it takes to animate
    // away on this screen; the server no longer has it.
    final shown = message.deletion == MessageDeletion.vanished
        ? Message(
            id: old.id,
            conversationId: old.conversationId,
            senderId: old.senderId,
            body: old.body,
            createdAt: old.createdAt,
            deletion: MessageDeletion.vanished,
          )
        : message;
    state = AsyncData([...current]..[i] = shown);
  }

  /// An edited message replaces its old self, in place, on this screen --
  /// and on every other open screen through the same Realtime update.
  void _edited(Message message) {
    final current = state.value;
    if (current == null) return;
    final i = current.indexWhere((m) => m.id == message.id);
    if (i < 0) return;
    state = AsyncData([...current]..[i] = message);
  }

  /// Deletes [message] for everyone (the member's own, or any member's when
  /// they are a group admin). The placeholder shows here at once and is
  /// rolled back when the server refuses; other open screens get it through
  /// Realtime.
  Future<Result<void>> deleteForEveryone(Message message) async {
    _ownEdits++;
    _deleted(
      Message(
        id: message.id,
        conversationId: message.conversationId,
        senderId: message.senderId,
        body: '',
        createdAt: message.createdAt,
        deletion: MessageDeletion.placeholder,
        deletedBy: _me,
      ),
    );
    final result = await ref
        .read(chatRepositoryProvider)
        .deleteForEveryone(message);
    if (result is Err && ref.mounted) _replace(message);
    return result;
  }

  /// Hides [message] from this member only (delete for me). It leaves the
  /// list at once and comes back when the server refuses.
  Future<Result<void>> hideForMe(Message message) async {
    _ownEdits++;
    final current = state.value;
    if (current != null) {
      state = AsyncData([
        for (final m in current)
          if (m.id != message.id) m,
      ]);
    }
    final result = await ref.read(chatRepositoryProvider).hideForMe(message);
    if (result is Err && ref.mounted) {
      final now = state.value;
      if (now != null && !now.any((m) => m.id == message.id)) {
        state = AsyncData(
          [...now, message]..sort((a, b) => a.createdAt.compareTo(b.createdAt)),
        );
      }
    }
    return result;
  }

  /// Puts [message] back in its place (a refused delete), keeping every
  /// other change made meanwhile.
  void _replace(Message message) {
    final current = state.value;
    if (current == null) return;
    final i = current.indexWhere((m) => m.id == message.id);
    if (i < 0) return;
    state = AsyncData([...current]..[i] = message);
  }

  /// Edits the member's own [message] to [body]. The screen shows an [Err]'s
  /// reason; on success the new text shows here at once, and on every other
  /// open screen through Realtime.
  Future<Result<Message>> editMessage(Message message, String body) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .editMessage(message, body);
    if (result case Ok(:final value) when ref.mounted) {
      _edited(value);
    }
    return result;
  }

  void _append(Message message) {
    // A jumped window has no live end: a live row is read when paging down
    // (loadNewer); appending it here would leave a gap.
    if (_jumped) return;
    final current = state.value;
    if (current == null) return;
    final i = current.indexWhere((m) => m.id == message.id);
    if (i < 0) {
      // My own photo's stored row (the Realtime echo or the POST answer,
      // whichever is first) takes the pending bubble's place and keeps its
      // local image: one bubble, never two, and no swap to the downloaded
      // copy. Matched by caption and the photo's own preview (see
      // Message.isPendingOf), so photos in the air together never swap.
      final p = message.attachmentPath != null && message.isFrom(_me ?? '')
          ? current.indexWhere((m) => m.isPendingOf(message))
          : -1;
      state = AsyncData(
        p >= 0
            ? ([...current]
                ..[p] = message.withLocalImage(current[p].localImage))
            : [...current, message],
      );
    } else if (!identical(current[i], message)) {
      // The echo and the answer are both this message: keep the phone's
      // own photo across the second one.
      final kept = current[i].localImage;
      state = AsyncData(
        [...current]
          ..[i] = message.localImage == null && kept != null
              ? message.withLocalImage(kept)
              : message,
      );
    }
  }

  /// Sends [chosen], picked in the attachment sheet's own grid, with an
  /// optional [body].
  ///
  /// Returns null when [chosen] is null -- the member backed out of the
  /// sheet, which is not a failure, and the composer must not report one.
  Future<Result<Message>?> sendImage({
    String body = '',
    PickedImage? chosen,
  }) async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return const Err(DeniedFailure());
    final image = chosen;
    if (image == null) return null;

    // Shown at once from the phone while it uploads; replaced by the stored
    // message, or taken away again if the upload fails.
    final pending = Message(
      id: 'pending-${DateTime.now().microsecondsSinceEpoch}',
      conversationId: conversationId,
      senderId: _me ?? '',
      body: body.trim(),
      createdAt: DateTime.now(),
      localImage: image.bytes,
      attachmentPreview: image.preview,
    );
    returnToLive(); // no-op unless jumped; see _onQueueChanged
    _append(pending);
    final result = await ref
        .read(chatRepositoryProvider)
        .sendImage(
          conversationId: conversationId,
          image: image,
          body: body,
          replyTo: ref.read(replyingToProvider)?.id,
        );
    if (!ref.mounted) return result;
    // Stored row first: it takes the pending bubble's place (see _append),
    // so the photo never leaves the screen. Whatever pending is left over
    // (a failed send) is removed after.
    if (result case Ok(:final value)) {
      _append(value);
      if (ref.mounted) ref.read(replyingToProvider.notifier).clear();
    }
    final current = state.value;
    if (current != null && current.any((m) => m.id == pending.id)) {
      state = AsyncData([
        for (final m in current)
          if (m.id != pending.id) m,
      ]);
    }
    return result;
  }

  /// Sends [images] to the open conversation, one message per photo, in
  /// order -- [body] as the caption of the first only, the rest with none.
  /// Stops at the first [Err] and returns it; otherwise returns [Ok(null)]
  /// once every image has been sent. An empty [images] sends nothing and
  /// returns [Ok(null)] at once.
  Future<Result<void>> sendImages(
    List<PickedImage> images, {
    String body = '',
  }) async {
    for (var i = 0; i < images.length; i++) {
      final result = await sendImage(
        body: i == 0 ? body : '',
        chosen: images[i],
      );
      switch (result) {
        case null:
          // sendImage only answers null for a null `chosen`; images[i] is
          // never null, so this never happens -- kept for exhaustiveness.
          break;
        case Ok():
          break;
        case Err(:final failure):
          return Err(failure);
      }
    }
    return const Ok(null);
  }

  /// A short-lived URL for an attachment, or an [Err] with its reason.
  Future<Result<Uri>> attachmentUrl(String path) =>
      ref.read(chatRepositoryProvider).attachmentUrl(path);

  /// Sends a copy of [message] to each of [conversationIds]; the chat list
  /// then shows them.
  Future<Result<void>> forward(
    Message message,
    List<String> conversationIds,
  ) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .forward(message, conversationIds);
    if (result is Ok && ref.mounted) {
      unawaited(ref.read(conversationListProvider.notifier).reloadQuietly());
    }
    return result;
  }

  /// Forwards [message] to [conversationIds] and to [personIds]: a person
  /// with no chat yet gets a direct chat first (created on send). The first
  /// chat that cannot be created is the [Err]; nothing is sent then.
  Future<Result<void>> forwardTo(
    Message message, {
    required List<String> conversationIds,
    List<String> personIds = const [],
  }) async {
    final ids = [...conversationIds];
    for (final person in personIds) {
      final started = await ref
          .read(conversationListProvider.notifier)
          .startWith(person);
      switch (started) {
        case Ok(:final value):
          if (!ids.contains(value)) ids.add(value);
        case Err(:final failure):
          return Err(failure);
      }
    }
    return forward(message, ids);
  }

  /// Replaces the shown messages with a window around [anchor] (oldest
  /// first, anchor included) -- for jumping to a search hit older than what
  /// is currently loaded. The [Err] reason is the caller's to show; state is
  /// left as it was on failure. Call [returnToLive] to go back to the live,
  /// newest window.
  Future<Result<void>> jumpToAround(Message anchor) async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return const Err(DeniedFailure());
    _requestedAnchorId = anchor.id;
    final result = await ref
        .read(chatRepositoryProvider)
        .messagesAround(conversationId, anchor);
    if (result case Ok(:final value)
        when ref.mounted &&
            ref.read(openConversationProvider) == conversationId &&
            _requestedAnchorId == anchor.id) {
      if (!_jumped) _liveBeforeJump = state.value;
      _jumped = true;
      // A page read for the old list must not land in this window.
      _epoch++;
      _loadingOlder = false;
      _loadingNewer = false;
      ref.read(olderLoadingProvider.notifier).set(false);
      _noOlder = false;
      state = AsyncData(value);
    }
    return switch (result) {
      Ok() => const Ok(null),
      Err(:final failure) => Err(failure),
    };
  }

  /// Back to the live, newest window -- undoes [jumpToAround]. The live list
  /// shown before the jump is back at once (no network wait) and the re-read
  /// heals it. A no-op when nothing was jumped.
  void returnToLive() {
    if (!_jumped) return;
    _jumped = false;
    final live = _liveBeforeJump;
    _liveBeforeJump = null;
    if (live != null) {
      state = AsyncData(live);
    } else {
      _fromJump = true;
    }
    ref.invalidateSelf();
  }
}

/// The message the composer is answering, or null. Cleared when another
/// conversation opens and after the reply is sent.
final replyingToProvider = NotifierProvider<ReplyingTo, Message?>(
  ReplyingTo.new,
);

class ReplyingTo extends Notifier<Message?> {
  @override
  Message? build() {
    ref.watch(openConversationProvider);
    return null;
  }

  void start(Message message) => state = message;

  void clear() => state = null;
}

/// The message being edited in the composer, or null. Cleared when another
/// conversation opens and after the edit is saved or cancelled.
final editingProvider = NotifierProvider<Editing, Message?>(Editing.new);

class Editing extends Notifier<Message?> {
  @override
  Message? build() {
    ref.watch(openConversationProvider);
    return null;
  }

  void start(Message message) => state = message;

  void clear() => state = null;
}

Future<T> _value<T>(Future<Result<T>> call) async => switch (await call) {
  Ok(:final value) => value,
  Err(:final failure) => throw failure,
};

/// Who is in a conversation, for its group page.
final conversationMembersProvider = FutureProvider.autoDispose
    .family<List<Member>, String>((ref, id) {
      // Per account: what a member may read depends on who "you" are.
      ref.watch(currentUserIdProvider);
      return _value(ref.read(chatRepositoryProvider).conversationMembers(id));
    }, retry: _never);

/// A conversation's photos, newest first.
final sharedMediaProvider = FutureProvider.autoDispose
    .family<List<Message>, String>((ref, id) {
      ref.watch(currentUserIdProvider);
      return _value(ref.read(chatRepositoryProvider).sharedMedia(id));
    }, retry: _never);

/// A conversation's links, newest first.
final sharedLinksProvider = FutureProvider.autoDispose
    .family<List<SharedLink>, String>((ref, id) async {
      ref.watch(currentUserIdProvider);
      return sharedLinksIn(
        await _value(ref.read(chatRepositoryProvider).sharedLinks(id)),
      );
    }, retry: _never);

/// How far the other members of the open conversation have read, live.
/// Empty when nothing is shared: messages then simply look normal. Rebuilt
/// when the member turns their own read status on or off.
final readMarksProvider =
    AsyncNotifierProvider.autoDispose<ReadMarksController, List<ReadMark>>(
      ReadMarksController.new,
      retry: _never,
    );

class ReadMarksController extends AsyncNotifier<List<ReadMark>> {
  // Reads that arrive while a load is on its way, applied once it lands.
  final _early = <ReadMark>[];

  @override
  Future<List<ReadMark>> build() async {
    _early.clear();
    final conversationId = ref.watch(openConversationProvider);
    ref.watch(currentUserIdProvider);
    ref.watch(ownProfileProvider.select((p) => p.value?.shareReadStatus));
    if (conversationId == null) return const [];
    // Watched: a group discovered to be one the member has left or been
    // removed from (leftConversationGuardProvider) rebuilds this at once and
    // leaves the reads:<id> channel, same reasoning as Typing.build() in
    // presence/application/presence_controllers.dart. The select folds
    // "not found yet / still loading" and "found, not left" to the same
    // `false` so the loading -> loaded transition does not itself count as
    // a change and resubscribe a second channel -- only an actual
    // left/removed flip does.
    final hasLeft = ref.watch(
      conversationListProvider.select(
        (s) =>
            (s.value ?? const <Conversation>[])
                .where((c) => c.id == conversationId)
                .firstOrNull
                ?.hasLeft ==
            true,
      ),
    );
    if (hasLeft) return const [];
    final repo = ref.read(chatRepositoryProvider);
    // Subscribed before the read, so a read in between is not lost; a
    // failed subscription only costs the live part.
    final updates = await repo.readUpdates(conversationId);
    if (updates case Ok(:final value)) {
      final sub = value.listen(_saw);
      ref.onDispose(sub.cancel);
    }
    final loaded = switch (await repo.readMarks(conversationId)) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
    return _early.fold<List<ReadMark>>(loaded, _merged);
  }

  void _saw(ReadMark mark) {
    final current = state.value;
    if (state.isLoading || current == null) {
      _early.add(mark);
      return;
    }
    state = AsyncData(_merged(current, mark));
  }

  /// [marks] with [mark] applied: only a later read moves a member's mark.
  static List<ReadMark> _merged(List<ReadMark> marks, ReadMark mark) => [
    for (final m in marks)
      if (m.userId == mark.userId &&
          (m.readAt == null || mark.readAt!.isAfter(m.readAt!)))
        mark
      else
        m,
  ];
}

/// Search inside the open conversation, and where the member is looking
/// among the hits.
final class ChatSearchState {
  const ChatSearchState({
    this.query = '',
    this.hits = const [],
    this.index = -1,
    this.serverAnswered = false,
    this.failure,
  });

  /// What was searched for; empty means the search box is closed.
  final String query;

  /// Hits in the open conversation, newest first: local-only until the
  /// server has answered, then the merged, authoritative set.
  final List<Message> hits;

  /// Which hit is current, or -1 when there are none (no search yet, or no
  /// match).
  final int index;

  /// Whether the server has answered for [query] in this conversation yet.
  /// Until then [hits] is only what this phone already has loaded, and may
  /// be incomplete -- the search bar shows a '+' and stepping past the
  /// oldest hit asks the server.
  final bool serverAnswered;

  /// A failure from asking the server while stepping past the oldest local
  /// hit -- the search bar shows it once, as a notice. Reset by the next
  /// state change (a new search, a move, a fresh answer); never set by
  /// [ChatSearchController.search] itself, whose own failure already goes
  /// straight back to its caller.
  final Failure? failure;

  Message? get current =>
      index >= 0 && index < hits.length ? hits[index] : null;
}

final chatSearchProvider =
    NotifierProvider<ChatSearchController, ChatSearchState>(
      ChatSearchController.new,
    );

/// In-chat search: instant from the messages already loaded on this phone,
/// the server asked only when there is nothing local to show, or when the
/// member steps past the oldest local hit looking for an older one. Jumping
/// between hits with next/previous is clamped at the ends -- it does not
/// wrap, so reaching the oldest or newest hit and asking for another simply
/// stays there (after asking the server once, for the oldest end).
class ChatSearchController extends Notifier<ChatSearchState> {
  @override
  ChatSearchState build() {
    // Closed whenever a different conversation opens.
    ref.watch(openConversationProvider);
    return const ChatSearchState();
  }

  /// Searches the open conversation for [query]. Hits already loaded on this
  /// phone (the open conversation's [messagesProvider] state) show at once,
  /// synchronously, before any round trip -- same fold and substring rule
  /// the server applies (see [foldSearch]), so a match here is a match
  /// there. The server is asked only when there is no local hit at all; the
  /// [Err] reason is then the caller's to show, same as
  /// [MessagesController.editMessage]. A local hit needs no round trip, so
  /// this only fails when the server had to be asked and refused.
  Future<Result<void>> search(String query) async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return const Err(DeniedFailure());
    if (!isSearchable(query)) {
      state = ChatSearchState(query: query);
      return const Ok(null);
    }
    final messages = ref.read(messagesProvider.notifier);
    if (messages.isJumped) {
      // A new query is about the chat's current, live state -- not whatever
      // old window a previous hit jumped to. Go back to the newest 500 first
      // (same as closing search does), and wait for it: there is nothing
      // local to show from an old, replaced window.
      state = ChatSearchState(query: query);
      messages.returnToLive();
      await ref.read(messagesProvider.future);
      if (!ref.mounted ||
          ref.read(openConversationProvider) != conversationId ||
          state.query != query) {
        return const Ok(null);
      }
    }
    final local = _localHits(conversationId, query);
    state = ChatSearchState(
      query: query,
      hits: local,
      index: local.isEmpty ? -1 : 0,
    );
    if (local.isEmpty) {
      return _askServer(conversationId, query);
    }
    return const Ok(null);
  }

  /// Messages already loaded for [conversationId] whose body contains
  /// [query], newest first -- deleted/vanished and attachment-only (empty
  /// body) messages excluded, exactly what the server's own search excludes.
  /// [messagesProvider] keeps the previous conversation's list visible while
  /// a newly opened one is still loading, so [conversationId] is checked
  /// here too, not just at the call site -- otherwise a chat just left can
  /// answer for the one just opened.
  List<Message> _localHits(String conversationId, String query) {
    final loaded = ref.read(messagesProvider).value ?? const <Message>[];
    final folded = foldSearch(query);
    return [
      for (final m in loaded.reversed)
        if (m.conversationId == conversationId &&
            !m.isDeleted &&
            m.body.isNotEmpty &&
            foldSearch(m.body).contains(folded))
          m,
    ];
  }

  /// Asks the server for [query] in [conversationId] and merges its answer
  /// into [state.hits], de-duplicated by message id, newest first. Ignored
  /// when a newer search or a different conversation has since taken over --
  /// the same stale-answer guard [MessagesController.jumpToAround] uses.
  Future<Result<void>> _askServer(String conversationId, String query) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .search(query, conversationId: conversationId);
    if (result case Ok(:final value)
        when ref.mounted &&
            ref.read(openConversationProvider) == conversationId &&
            state.query == query) {
      final currentId = state.current?.id;
      final merged = _merge(state.hits, value);
      final restored = currentId == null
          ? -1
          : merged.indexWhere((m) => m.id == currentId);
      state = ChatSearchState(
        query: query,
        hits: merged,
        index: restored >= 0 ? restored : (merged.isEmpty ? -1 : 0),
        serverAnswered: true,
      );
    }
    return switch (result) {
      Ok() => const Ok(null),
      Err(:final failure) => Err(failure),
    };
  }

  /// [local] and [server] merged by message id, newest first.
  static List<Message> _merge(List<Message> local, List<Message> server) {
    final seen = {for (final m in local) m.id};
    final merged = [
      ...local,
      for (final m in server)
        if (seen.add(m.id)) m,
    ];
    merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return merged;
  }

  /// Closes the search: no query, no hits, nothing current.
  void close() => state = const ChatSearchState();

  /// Makes the hit with [messageId] current, when it is among [state.hits] --
  /// for opening a conversation already jumped to one particular result (the
  /// chat list's own search leads here). A no-op otherwise.
  void select(String messageId) {
    final index = state.hits.indexWhere((m) => m.id == messageId);
    if (index < 0) return;
    state = ChatSearchState(
      query: state.query,
      hits: state.hits,
      index: index,
      serverAnswered: state.serverAnswered,
    );
  }

  /// Moves toward an older hit (hits are newest first, so a higher index).
  /// Already on the oldest local hit and the server has not answered for
  /// this query yet: asks it first, in case it holds an older one, then
  /// moves on if it did.
  void next() {
    if (state.hits.isEmpty) return;
    if (state.index >= state.hits.length - 1 && !state.serverAnswered) {
      unawaited(_stepPastOldest());
      return;
    }
    _move(1);
  }

  /// Moves toward a newer hit (a lower index).
  void previous() => _move(-1);

  void _move(int delta) {
    if (state.hits.isEmpty) return;
    state = ChatSearchState(
      query: state.query,
      hits: state.hits,
      index: (state.index + delta).clamp(0, state.hits.length - 1),
      serverAnswered: state.serverAnswered,
    );
  }

  Future<void> _stepPastOldest() async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return;
    final query = state.query;
    final before = state.hits.length;
    final result = await _askServer(conversationId, query);
    if (!ref.mounted ||
        ref.read(openConversationProvider) != conversationId ||
        state.query != query) {
      return;
    }
    if (result case Err(:final failure)) {
      // Unlike search()'s own failure, nothing awaits this call directly
      // (next() is fire-and-forget) -- carried in state instead, for the
      // search bar to show as a notice. Hits/index/serverAnswered are left
      // exactly as they were: a failed step forward is not an answer.
      state = ChatSearchState(
        query: state.query,
        hits: state.hits,
        index: state.index,
        serverAnswered: state.serverAnswered,
        failure: failure,
      );
      return;
    }
    if (state.hits.length > before) _move(1);
  }
}

/// The chat list's own search box: every conversation the caller belongs to.
final class ChatListSearchState {
  const ChatListSearchState({
    this.query = '',
    this.results = const [],
    this.failure,
  });

  final String query;

  /// Hits across every conversation, newest first.
  final List<Message> results;

  /// The last search failure, if any -- for the screen to show as a notice
  /// while [results] stays whatever it was before. Cleared by the next
  /// search attempt, success or failure.
  final Failure? failure;
}

final chatListSearchProvider =
    NotifierProvider<ChatListSearchController, ChatListSearchState>(
      ChatListSearchController.new,
    );

class ChatListSearchController extends Notifier<ChatListSearchState> {
  Timer? _debounce;

  /// Bumped on every keystroke; a response is applied only when it is still
  /// the latest one asked for, so a slow answer to an old query can never
  /// overwrite a newer one still in flight.
  int _generation = 0;

  @override
  ChatListSearchState build() {
    // Fresh per account, like every other search/list here.
    ref.watch(currentUserIdProvider);
    // Invalidates any request already in flight for the previous account.
    _generation++;
    ref.onDispose(() => _debounce?.cancel());
    return const ChatListSearchState();
  }

  /// Debounces [query] ~300ms, then searches every conversation the caller
  /// belongs to. Fewer than three letters or digits -- including empty --
  /// clears the results at once, with no round trip.
  void search(String query) {
    _debounce?.cancel();
    if (!isSearchable(query)) {
      _generation++;
      state = const ChatListSearchState();
      return;
    }
    final generation = ++_generation;
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      final result = await ref.read(chatRepositoryProvider).search(query);
      if (!ref.mounted || generation != _generation) return;
      switch (result) {
        case Ok(:final value):
          state = ChatListSearchState(query: query, results: value);
        case Err(:final failure):
          // The list stays usable: only the failure is new, not the results.
          state = ChatListSearchState(
            query: query,
            results: state.results,
            failure: failure,
          );
      }
    });
  }

  /// Clears the search box: back to the plain conversation list.
  void clear() => search('');
}
