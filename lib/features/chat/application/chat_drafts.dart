import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../domain/file_attachment.dart';
import '../domain/message.dart';
import 'chat_controllers.dart';

/// One conversation's composer state kept while it is off screen: the typed
/// text and who it replies to, if anyone. Never written to disk -- see
/// [DraftsController]. Edit mode is never a draft (see message_screen.dart's
/// `_ComposerState`): its text lives only in the text field while editing,
/// never here.
final class Draft {
  const Draft({this.text = '', this.replyTo, this.failure});

  final String text;
  final Message? replyTo;

  /// A failed send's reason, waiting to be shown once -- see
  /// [DraftsController.consumeFailure]. Never re-shown once consumed, even
  /// though the rest of the draft (text, reply target) lives on.
  final Failure? failure;

  bool get isEmpty => text.isEmpty && replyTo == null && failure == null;
}

/// Every conversation's draft, keyed by id. Kept only while the app runs
/// (never written to disk, per "Unsent text stays in each chat", 2026-09-28)
/// and cleared for a new account, like every other per-account state here.
final draftsProvider = NotifierProvider<DraftsController, Map<String, Draft>>(
  DraftsController.new,
);

class DraftsController extends Notifier<Map<String, Draft>> {
  @override
  Map<String, Draft> build() {
    ref.watch(currentUserIdProvider);
    return const {};
  }

  Draft draftFor(String conversationId) =>
      state[conversationId] ?? const Draft();

  /// The composer's live text changed; the reply target is unaffected.
  void setText(String conversationId, String text) {
    final current = draftFor(conversationId);
    _apply(
      conversationId,
      Draft(text: text, replyTo: current.replyTo, failure: current.failure),
    );
  }

  /// The composer's reply target changed (started or cleared); the text is
  /// unaffected.
  void setReply(String conversationId, Message? replyTo) {
    final current = draftFor(conversationId);
    _apply(
      conversationId,
      Draft(text: current.text, replyTo: replyTo, failure: current.failure),
    );
  }

  /// Ends the draft outright: sending, or the box emptied with nothing left
  /// to reply to.
  void clear(String conversationId) {
    if (!state.containsKey(conversationId)) return;
    state = {...state}..remove(conversationId);
  }

  /// A failed send's unsent [bodies] (typed order) go back in front of
  /// whatever is already drafted, joined with a newline; the reply target is
  /// restored only when the draft has none of its own; [failure] is stashed
  /// to show once -- at once if this conversation's composer is already
  /// open, or the next time it opens.
  void restoreFailure(
    String conversationId,
    List<String> bodies,
    Message? replyTo,
    Failure failure,
  ) {
    final current = draftFor(conversationId);
    final prepend = bodies.join('\n');
    final text = prepend.isEmpty
        ? current.text
        : current.text.isEmpty
        ? prepend
        : '$prepend\n${current.text}';
    _apply(
      conversationId,
      Draft(text: text, replyTo: current.replyTo ?? replyTo, failure: failure),
    );
  }

  /// Removes and returns [conversationId]'s pending failure, if any -- so
  /// the composer shows the notice exactly once.
  Failure? consumeFailure(String conversationId) {
    final current = state[conversationId];
    if (current?.failure == null) return null;
    _apply(
      conversationId,
      Draft(text: current!.text, replyTo: current.replyTo),
    );
    return current.failure;
  }

  void _apply(String conversationId, Draft draft) {
    if (draft.isEmpty) {
      clear(conversationId);
    } else {
      state = {...state, conversationId: draft};
    }
  }
}

/// One text send not yet stored: the pending bubble shown for it, the body
/// and reply target exactly as typed (for [SendQueueController._drain] to
/// retry or hand back to the draft). A file send carries the picked [file]
/// and an empty body.
class _QueuedSend {
  _QueuedSend({
    required this.message,
    required this.body,
    required this.replyTo,
    this.file,
  });

  final Message message;
  final String body;
  final Message? replyTo;
  final PickedFile? file;
}

/// Pending text bubbles per conversation, oldest first -- for
/// [MessagesController] to show while a send is queued, in flight, or
/// retrying after a network failure, even across leaving and reopening the
/// conversation (see MessagesController.build and _onQueueChanged, which
/// listen to this independently of which conversation is on screen).
final sendQueueProvider =
    NotifierProvider<SendQueueController, Map<String, List<Message>>>(
      SendQueueController.new,
    );

/// One send queue per conversation, serialized in typed order within it,
/// independent across conversations -- a slow or offline chat A never
/// delays chat B, and a failure in A stops only A's queue. Lives
/// independently of any open [MessagesController]: enqueued sends keep
/// draining in the background whichever conversation (if any) is on screen.
class SendQueueController extends Notifier<Map<String, List<Message>>> {
  final _queues = <String, List<_QueuedSend>>{};
  final _draining = <String>{};
  final _retries = <String, int>{};
  final _timers = <String, Timer>{};

  /// True from [pauseForBackground] to [resumeForeground] -- while paused,
  /// [_drain] leaves a retryable failure queued without scheduling a new
  /// timer, so a send that fails just as the app backgrounds does not wake
  /// it later on its own; [resumeForeground] retries everything at once.
  bool _paused = false;

  @override
  Map<String, List<Message>> build() {
    ref.watch(currentUserIdProvider);
    // A new owner (or none: Denied, signed out) starts with nothing queued --
    // a revoked member's waiting sends are dropped, never retried.
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _queues.clear();
    _retries.clear();
    _draining.clear();
    ref.onDispose(() {
      for (final t in _timers.values) {
        t.cancel();
      }
    });
    return const {};
  }

  String? get _me => switch (ref.read(sessionControllerProvider).value) {
    Allowed(:final member) => member.userId,
    _ => null,
  };

  /// Queues [body] for [conversationId] and returns the pending bubble at
  /// once. Clears the live reply target and that conversation's draft --
  /// a message just sent is no longer a draft -- and starts (or continues)
  /// draining that conversation's queue.
  Message enqueue(
    String conversationId, {
    required String body,
    Message? replyTo,
  }) {
    final message = Message(
      id: randomMessageId(),
      conversationId: conversationId,
      senderId: _me ?? '',
      body: body.trim(),
      createdAt: DateTime.now(),
      sending: true,
      replyTo: replyTo?.id,
    );
    _queues
        .putIfAbsent(conversationId, () => [])
        .add(_QueuedSend(message: message, body: body, replyTo: replyTo));
    _publish(conversationId);
    ref.read(replyingToProvider.notifier).clear();
    ref.read(draftsProvider.notifier).clear(conversationId);
    unawaited(_drain(conversationId));
    return message;
  }

  /// Drops everything queued for [conversationId] outright, and cancels any
  /// retry it was waiting on -- used when the member has left or been
  /// removed from it (see GroupController), never sent into a conversation
  /// they can no longer write to. Unlike a refused send ([_drain]'s own
  /// [Err] path), the bodies are not worth restoring to the draft: the
  /// conversation itself explains why, in its disabled write box. Returns
  /// whether anything was actually dropped, so the caller can decide
  /// whether "unsent messages were not sent" needs saying.
  bool dropForLeft(String conversationId) {
    final items = _queues.remove(conversationId);
    _timers.remove(conversationId)?.cancel();
    _retries.remove(conversationId);
    _draining.remove(conversationId);
    if (items == null || items.isEmpty) return false;
    _publish(conversationId);
    return true;
  }

  /// Queues [file] for [conversationId] like [enqueue] and returns the pending
  /// bubble at once (id = the file's own id). Unlike [enqueue] the typed draft
  /// text stays: only the reply target is spent.
  Message enqueueFile(
    String conversationId,
    PickedFile file, {
    Message? replyTo,
  }) {
    final message = Message(
      id: file.id,
      conversationId: conversationId,
      senderId: _me ?? '',
      body: '',
      createdAt: DateTime.now(),
      sending: true,
      replyTo: replyTo?.id,
      file: file.attached,
    );
    _queues
        .putIfAbsent(conversationId, () => [])
        .add(
          _QueuedSend(message: message, body: '', replyTo: replyTo, file: file),
        );
    _publish(conversationId);
    ref.read(replyingToProvider.notifier).clear();
    ref.read(draftsProvider.notifier).setReply(conversationId, null);
    unawaited(_drain(conversationId));
    return message;
  }

  void _publish(String conversationId) {
    final items = _queues[conversationId];
    final next = {...state};
    if (items == null || items.isEmpty) {
      next.remove(conversationId);
    } else {
      next[conversationId] = [for (final i in items) i.message];
    }
    state = next;
  }

  /// Cancels every scheduled retry without touching what is queued -- a
  /// chat waiting out a network failure just waits silently until
  /// [resumeForeground], instead of burning through backoff attempts (or
  /// waking the OS) while nobody can see the result. Wired from
  /// `AppLifecycleListener.onHide` in app/sis_app.dart's `SessionGate`.
  void pauseForBackground() {
    _paused = true;
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  /// Retries every conversation with something still queued at once, from a
  /// fresh backoff ladder -- returning to the app should feel like normal
  /// sending, not like waiting out whatever was left of the previous delay.
  /// Wired from `AppLifecycleListener.onResume` in app/sis_app.dart's
  /// `SessionGate`, the same hook that already rechecks for an update.
  void resumeForeground() {
    _paused = false;
    _retries.clear();
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    for (final conversationId in _queues.keys.toList()) {
      unawaited(_drain(conversationId));
    }
  }

  /// Sends [conversationId]'s queued items to the server, one at a time, in
  /// order. A network-type failure ([NetworkFailure.retryable]) leaves the queue
  /// exactly as it was -- nothing removed, nothing sent back to the draft,
  /// no per-message notice, the app's own offline state is enough -- and
  /// schedules a retry with backoff (see [_backoff]); any other failure
  /// (a refusal) stops the queue and hands everything still in it back to
  /// [DraftsController.restoreFailure] with one notice.
  Future<void> _drain(String conversationId) async {
    if (_draining.contains(conversationId)) return;
    _draining.add(conversationId);
    while (true) {
      final items = _queues[conversationId];
      if (items == null || items.isEmpty) break;
      final item = items.first;
      final file = item.file;
      final result = file != null
          ? await ref
                .read(chatFileRepositoryProvider)
                .send(conversationId, file, replyTo: item.replyTo?.id)
          : await ref
                .read(chatRepositoryProvider)
                .send(
                  id: item.message.id,
                  conversationId: conversationId,
                  body: item.body,
                  replyTo: item.replyTo?.id,
                );
      if (!ref.mounted) return;
      switch (result) {
        case Ok(:final value):
          _retries.remove(conversationId);
          items.removeAt(0);
          // Published once with the stored row in place of the pending
          // bubble, so a listening MessagesController can upsert it by id
          // before the very next publish drops it from here for good.
          final resolved = {...state};
          resolved[conversationId] = [value, for (final i in items) i.message];
          state = resolved;
          _publish(conversationId);
        case Err(:final failure):
          if (failure is NetworkFailure && failure.retryable) {
            final attempt = (_retries[conversationId] ?? 0) + 1;
            _retries[conversationId] = attempt;
            _draining.remove(conversationId);
            if (_paused) return;
            _timers[conversationId]?.cancel();
            _timers[conversationId] = Timer(_backoff(attempt), () {
              _timers.remove(conversationId);
              if (ref.mounted) unawaited(_drain(conversationId));
            });
            return;
          }
          final stopped = List<_QueuedSend>.of(items);
          items.clear();
          _retries.remove(conversationId);
          _publish(conversationId);
          ref
              .read(draftsProvider.notifier)
              .restoreFailure(
                conversationId,
                [
                  for (final s in stopped)
                    if (s.body.isNotEmpty) s.body,
                ],
                stopped.map((s) => s.replyTo).whereType<Message>().firstOrNull,
                failure,
              );
      }
    }
    _draining.remove(conversationId);
  }

  // ponytail: a fixed delay ladder capped at 5s (owner: 30s left a message
  // waiting too long after reconnecting) -- paused while the app is
  // backgrounded (pauseForBackground) and every waiting chat is retried at
  // once on resume (resumeForeground), so the ladder itself only ever has
  // to cover a foreground blip. No Realtime-reconnect hook: this app
  // exposes no "socket reconnected" signal to application/ code today (the
  // realtime client's own status callbacks live behind supabase_flutter,
  // which only data/ may import); wiring one would mean a new
  // ChatRepository method, out of scope here. App-resume already covers
  // the common case (phone regains a signal while backgrounded); upgrade
  // path: add such a method if a foreground drop turns out to matter too.
  static const _backoffSteps = [1, 2, 4, 5];

  Duration _backoff(int attempt) {
    final step = attempt - 1 < _backoffSteps.length
        ? attempt - 1
        : _backoffSteps.length - 1;
    return Duration(seconds: _backoffSteps[step]);
  }
}
