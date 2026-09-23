import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/member.dart';
import '../../auth/domain/session_state.dart';
import '../domain/attachment.dart';
import '../domain/chat_repository.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';

final chatRepositoryProvider = Provider<ChatRepository>(
  (_) => throw UnimplementedError('override in main'),
);
final attachmentSourceProvider = Provider<AttachmentSource>(
  (_) => throw UnimplementedError('override in main'),
);

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

  Future<List<Conversation>> _load() async {
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
  @override
  Future<List<Message>> build() async {
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
          if (merged.every((m) => m.id != message.id)) merged.add(message);
        }
        merged.sort((a, b) => a.createdAt.compareTo(b.createdAt));
        return merged;
    }
  }

  String? get _me => switch (ref.read(sessionControllerProvider).value) {
    Allowed(:final member) => member.userId,
    _ => null,
  };

  void _append(Message message) {
    final current = state.value;
    if (current == null) return;
    if (current.any((m) => m.id == message.id)) return;
    state = AsyncData([...current, message]);
  }

  /// Lets the member choose an image and sends it with an optional [body].
  ///
  /// Returns null when they back out of the picker — not a failure, and the
  /// composer must not report one.
  Future<Result<Message>?> sendImage({String body = ''}) async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return const Err(DeniedFailure());

    final PickedImage? image;
    try {
      image = await ref.read(attachmentSourceProvider).pickImage();
    } catch (e) {
      // A picker that throws must read as a reason on screen, like any other
      // platform failure.
      return Err(ProviderFailure('Could not open the photo picker: $e'));
    }
    if (image == null) return null;

    final result = await ref
        .read(chatRepositoryProvider)
        .sendImage(conversationId: conversationId, image: image, body: body);
    if (result case Ok(:final value)) _append(value);
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
    final result = await ref
        .read(chatRepositoryProvider)
        .send(conversationId: conversationId, body: body);
    if (result case Ok(:final value)) _append(value);
    return result;
  }
}
