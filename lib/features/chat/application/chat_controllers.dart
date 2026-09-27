import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/member.dart';
import '../../auth/domain/session_state.dart';
import '../../profile/application/profile_controller.dart';
import '../domain/attachment.dart';
import '../domain/chat_repository.dart';
import '../domain/conversation.dart';
import '../domain/gallery.dart';
import '../domain/links.dart';
import '../domain/message.dart';
import '../domain/read_marks.dart';

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

/// Photos already on this phone. Cleared on sign-out.
final attachmentCacheProvider = Provider<AttachmentCache>(
  (_) => throw UnimplementedError('override in main'),
);

/// Wipes the cache above as soon as the session is found to have ended --
/// signed out, or Denied (revoked or replaced on another device) -- so
/// nothing of a previous member's photos or pictures survives on this phone.
/// Mirrors pushInboxOwnerProvider's reach: every settled answer about the
/// session, not only the explicit sign-out button, and `fireImmediately`
/// catches a cold start that lands directly on one of those two states.
final attachmentCacheOwnerProvider = Provider<void>((ref) {
  ref.listen(sessionControllerProvider, (_, next) {
    switch (next.value) {
      case SignedOut() || Denied():
        unawaited(ref.read(attachmentCacheProvider).clear());
      case _:
    }
  }, fireImmediately: true);
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

/// Riverpod 3 retries a failed build automatically, which leaves the provider
/// loading-with-an-error indefinitely instead of settling on [AsyncError] — an
/// endless spinner where ARCHITECTURE requires a reason on screen. Worse, a
/// DeniedFailure is a refusal that no amount of retrying can turn into data.
/// Retries are off; [refresh] is the explicit way back.
Duration? _never(int retryCount, Object error) => null;

final conversationListProvider =
    AsyncNotifierProvider<ConversationListController, List<Conversation>>(
      ConversationListController.new,
      retry: _never,
    );

/// The conversation list. Failures surface as [AsyncError] carrying the
/// [Failure], so the screen always has a reason to show.
class ConversationListController extends AsyncNotifier<List<Conversation>> {
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
    final buffered = <Message>[];
    var loaded = false;
    final opened = await ref.read(chatRepositoryProvider).incomingAll();
    if (opened case Ok(:final value)) {
      final sub = value.listen(
        (message) {
          if (!loaded) {
            buffered.add(message);
          } else {
            _apply(message);
          }
        },
        // A dropped subscription only stops live updates; the re-read on
        // returning from a conversation still keeps the list current.
        onError: (Object _) {},
      );
      ref.onDispose(sub.cancel);
    }
    var list = await _load();
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
    return unknown ? await _load() : list;
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
      }
      return;
    }
    final next = _withMessage(current, message);
    if (next == null) {
      reloadQuietly();
    } else {
      state = AsyncData(next);
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
    final at = existing.lastMessageAt;
    // Not newer than the current preview -- a late delivery, or the same
    // message delivered twice -- leaves the list exactly as it was. Using
    // "older" here instead would let a duplicate move its conversation above
    // one with a genuinely newer message.
    if (at != null && !message.createdAt.isAfter(at)) return list;
    final updated = [...list]..removeAt(index);
    // Unread: someone else's message, in a conversation not on screen.
    final me = switch (ref.read(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    final counts =
        message.senderId != me &&
        ref.read(openConversationProvider) != message.conversationId;
    return [existing.withPreview(message, counts: counts), ...updated];
  }

  /// Marks [conversationId] read on the server, then clears its count here.
  /// A failure leaves the count as it was: better a stale badge than a
  /// conversation that looks read and is not.
  Future<void> markRead(String conversationId) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .markRead(conversationId);
    // Checked before touching state: the list can be disposed while the call
    // is in flight, and reading state then throws.
    if (result is! Ok || !ref.mounted) return;
    final current = state.value;
    if (current == null) return;
    state = AsyncData([
      for (final c in current) c.id == conversationId ? c.read() : c,
    ]);
  }

  /// Also drops the cached [membersProvider] snapshot: whenever this list
  /// has reason to re-read the server (cold start, refresh, a message
  /// anywhere), someone's profile picture may have changed too, and the
  /// next read of membersProvider should not still be the one from before
  /// this session's first load.
  Future<List<Conversation>> _load() async {
    ref.invalidate(membersProvider);
    return switch (await ref.read(chatRepositoryProvider).conversations()) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(_load);
  }

  /// Re-reads without showing a spinner: the list on screen stays while the
  /// new one loads. A failed background re-read keeps the list as it was
  /// rather than replacing something correct with an error the member did
  /// not ask for; the explicit [refresh] still reports failures.
  Future<void> reloadQuietly() async {
    final next = await AsyncValue.guard(_load);
    if (next is AsyncData<List<Conversation>> && ref.mounted) state = next;
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

/// Everyone else who can sign in — the picker for starting a first chat.
final membersProvider = FutureProvider<List<Member>>((ref) async {
  // "Everyone else" depends on who "you" are.
  ref.watch(currentUserIdProvider);
  return switch (await ref.read(chatRepositoryProvider).members()) {
    Ok(:final value) => value,
    Err(:final failure) => throw failure,
  };
}, retry: _never);

final messagesProvider =
    AsyncNotifierProvider<MessagesController, List<Message>>(
      MessagesController.new,
      retry: _never,
    );

/// Messages of the open conversation, oldest first.
///
/// The initial read and the Realtime stream are merged by message id. Nothing
/// is appended optimistically on send: the server assigns the id and the
/// timestamp, and the insert comes back through Realtime like any other, so
/// the sender's own message appears exactly once.
class MessagesController extends AsyncNotifier<List<Message>> {
  /// Whether the shown list is a [jumpToAround] snapshot rather than the
  /// live, newest window.
  bool _jumped = false;

  /// True while [jumpToAround] has replaced the shown list with an old
  /// window; false once live (including before any jump at all).
  bool get isJumped => _jumped;

  /// The anchor id of the most recent [jumpToAround] call -- an answer for
  /// any earlier one is dropped, even if it arrives later.
  String? _requestedAnchorId;

  @override
  Future<List<Message>> build() async {
    _jumped = false;
    final conversationId = ref.watch(openConversationProvider);
    if (conversationId == null) return const [];

    final repo = ref.read(chatRepositoryProvider);
    // Awaited first, and it resolves only once the server has confirmed the
    // subscription: Realtime replays nothing, so a message sent before that
    // moment would be missed here AND be too late for the read below.
    // Anything arriving during the read is buffered and reconciled by id.
    final stream = switch (await repo.incoming(conversationId)) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
    final buffered = <Message>[];
    var loaded = false;
    final sub = stream.listen((message) {
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
      if (!message.isFrom(_me ?? '')) {
        ref.read(conversationListProvider.notifier).markRead(conversationId);
      }
    });
    ref.onDispose(sub.cancel);

    switch (await repo.messages(conversationId)) {
      case Err(:final failure):
        throw failure;
      case Ok(:final value):
        loaded = true;
        final merged = [...value];
        for (final message in buffered) {
          final i = merged.indexWhere((m) => m.id == message.id);
          if (i < 0) {
            merged.add(message);
          } else if (message.isDeleted || message.editedAt != null) {
            merged[i] = message;
          }
        }
        merged.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        // Vanished before this screen opened: as if never sent. One that
        // vanishes while open stays long enough to animate away.
        return [
          for (final m in merged)
            if (m.deletion != MessageDeletion.vanished) m,
        ];
    }
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

  /// Deletes the member's own [message] for everyone. The screen shows an
  /// [Err]'s reason; on success the message vanishes or becomes "deleted"
  /// here at once, and on every other open screen through Realtime.
  Future<Result<void>> deleteForEveryone(Message message) async {
    final result = await ref
        .read(chatRepositoryProvider)
        .deleteForEveryone(message);
    if (result is Ok && ref.mounted) {
      final vanishes =
          DateTime.now().difference(message.createdAt) <
          const Duration(hours: 1);
      _deleted(
        Message(
          id: message.id,
          conversationId: message.conversationId,
          senderId: message.senderId,
          body: '',
          createdAt: message.createdAt,
          deletion: vanishes
              ? MessageDeletion.vanished
              : MessageDeletion.placeholder,
        ),
      );
    }
    return result;
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
    final current = state.value;
    if (current == null) return;
    if (current.any((m) => m.id == message.id)) return;
    state = AsyncData([...current, message]);
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
    );
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
    final current = state.value;
    if (current != null) {
      state = AsyncData([
        for (final m in current)
          if (m.id != pending.id) m,
      ]);
    }
    if (result case Ok(:final value)) {
      _append(value);
      if (ref.mounted) ref.read(replyingToProvider.notifier).clear();
    }
    return result;
  }

  /// A short-lived URL for an attachment, or an [Err] with its reason.
  Future<Result<Uri>> attachmentUrl(String path) =>
      ref.read(chatRepositoryProvider).attachmentUrl(path);

  /// Sends [body] to the open conversation. The [Err] reason is shown by the
  /// composer.
  ///
  /// The stored message is appended as soon as the server returns it, rather
  /// than waiting for the Realtime echo: a sender must see their own message
  /// even when the subscription is slow or gone. The echo is then discarded
  /// by the id check in [_append].
  Future<Result<Message>> send(String body) async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return const Err(DeniedFailure());
    final replyTo = ref.read(replyingToProvider)?.id;
    final result = await ref
        .read(chatRepositoryProvider)
        .send(conversationId: conversationId, body: body, replyTo: replyTo);
    if (result case Ok(:final value)) {
      _append(value);
      if (ref.mounted) ref.read(replyingToProvider.notifier).clear();
    }
    return result;
  }

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
      _jumped = true;
      state = AsyncData(value);
    }
    return switch (result) {
      Ok() => const Ok(null),
      Err(:final failure) => Err(failure),
    };
  }

  /// Back to the live, newest window -- undoes [jumpToAround]. A no-op when
  /// nothing was jumped.
  void returnToLive() {
    if (!_jumped) return;
    _jumped = false;
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
