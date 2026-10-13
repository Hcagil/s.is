import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../domain/conversation.dart';
import 'chat_controllers.dart';
import 'chat_selection_controller.dart';
import 'group_controller.dart';

/// Which text the undo bar shows.
enum ChatDeleteNotice { chat, chats, groupLeft, groupDeleted }

/// What the undo bar shows. A null [notice] means no bar.
class ChatDeleteState {
  const ChatDeleteState({this.notice, this.secondsLeft = 0, this.failure});

  final ChatDeleteNotice? notice;
  final int secondsLeft;

  /// A refusal waiting to be shown once (see [ChatDelete.consumeFailure]).
  final Failure? failure;
}

final chatDeleteProvider = NotifierProvider<ChatDelete, ChatDeleteState>(
  ChatDelete.new,
);

final class _Job {
  const _Job(this.chats, this.alsoForOthers);

  final List<Conversation> chats;
  final bool alsoForOthers;
}

/// Deleting chats from the list. The rows leave the list at once; nothing
/// reaches the server until the undo bar runs out (5 s) or another delete
/// starts, so Undo costs nothing and is never wrong.
class ChatDelete extends Notifier<ChatDeleteState> {
  _Job? _pending;
  Timer? _timer;

  @override
  ChatDeleteState build() {
    ref.watch(currentUserIdProvider);
    ref.onDispose(() => _timer?.cancel());
    _pending = null;
    return const ChatDeleteState();
  }

  /// Takes [chats] off the list and starts the undo countdown. A delete
  /// still waiting is committed first. [alsoForOthers] is the dialog's box:
  /// both sides for a 1:1, the whole group for an admin (one group only).
  void start(List<Conversation> chats, {required bool alsoForOthers}) {
    if (chats.isEmpty) return;
    if (_pending != null) unawaited(_commit());
    _pending = _Job(chats, alsoForOthers);
    ref.read(chatSelectionProvider.notifier).clear();
    ref.read(conversationListProvider.notifier).hideLocally([
      for (final c in chats) c.id,
    ]);
    final notice = chats.length > 1
        ? ChatDeleteNotice.chats
        : !chats.single.isGroup
        ? ChatDeleteNotice.chat
        : chats.single.isAdmin && alsoForOthers
        ? ChatDeleteNotice.groupDeleted
        : ChatDeleteNotice.groupLeft;
    state = ChatDeleteState(notice: notice, secondsLeft: 5);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!ref.mounted) {
        timer.cancel();
        return;
      }
      final left = state.secondsLeft - 1;
      if (left <= 0) {
        unawaited(_commit());
      } else {
        state = ChatDeleteState(notice: state.notice, secondsLeft: left);
      }
    });
  }

  /// Puts the waiting delete's rows back; nothing was sent.
  void undo() {
    final job = _pending;
    if (job == null) return;
    _timer?.cancel();
    _pending = null;
    ref.read(conversationListProvider.notifier).restoreLocally(job.chats);
    state = const ChatDeleteState();
  }

  /// The failure has been shown; keep only the bar.
  void consumeFailure() {
    if (state.failure == null) return;
    state = ChatDeleteState(
      notice: state.notice,
      secondsLeft: state.secondsLeft,
    );
  }

  Future<void> _commit() async {
    final job = _pending;
    if (job == null) return;
    _pending = null;
    _timer?.cancel();
    state = const ChatDeleteState();
    Failure? first;
    for (final c in job.chats) {
      final result = await _run(job, c);
      if (result case Err(:final failure)) first ??= failure;
      if (!ref.mounted) return;
    }
    final list = ref.read(conversationListProvider.notifier)
      ..forget([for (final c in job.chats) c.id]);
    await list.reloadQuietly();
    if (!ref.mounted) return;
    if (first != null) {
      state = ChatDeleteState(
        notice: state.notice,
        secondsLeft: state.secondsLeft,
        failure: first,
      );
    }
  }

  Future<Result<void>> _run(_Job job, Conversation c) async {
    final repo = ref.read(chatDeleteRepositoryProvider);
    if (!c.isGroup) {
      return job.alsoForOthers
          ? repo.deleteDirectChat(c.id)
          : repo.hideChat(c.id);
    }
    final groups = ref.read(groupControllerProvider);
    if (job.chats.length == 1 && c.isAdmin && job.alsoForOthers) {
      return groups.deleteGroup(c.id);
    }
    if (!c.hasLeft) {
      final left = await groups.leave(c.id);
      if (left case Err(:final failure)) return Err(failure);
    }
    return repo.hideChat(c.id);
  }
}
