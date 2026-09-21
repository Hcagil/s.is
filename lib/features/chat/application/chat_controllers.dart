import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/domain/member.dart';
import '../domain/chat_repository.dart';
import '../domain/conversation.dart';
import '../domain/message.dart';

final chatRepositoryProvider = Provider<ChatRepository>(
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
  String? build() => null;

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
  @override
  Future<List<Conversation>> build() => _load();

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
}

/// Everyone else who can sign in — the picker for starting a first chat.
final membersProvider = FutureProvider<List<Member>>((ref) async {
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
    final stream = await repo.incoming(conversationId);
    final buffered = <Message>[];
    var loaded = false;
    final sub = stream.listen((message) {
      if (!loaded) {
        buffered.add(message);
        return;
      }
      _append(message);
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

  void _append(Message message) {
    final current = state.value;
    if (current == null) return;
    if (current.any((m) => m.id == message.id)) return;
    state = AsyncData([...current, message]);
  }

  /// Sends [body] to the open conversation. The [Err] reason is shown by the
  /// composer; the message itself arrives through Realtime.
  Future<Result<void>> send(String body) async {
    final conversationId = ref.read(openConversationProvider);
    if (conversationId == null) return const Err(DeniedFailure());
    return ref
        .read(chatRepositoryProvider)
        .send(conversationId: conversationId, body: body);
  }
}
