// Hand-written fakes shared by controller and widget tests.
import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/update/domain/update_repository.dart';

class FakeAuth implements AuthRepository {
  FakeAuth({
    this.session = false,
    this.allowed = true,
    this.signInResult = const Ok(null),
  });
  bool session;
  bool allowed;
  Result<void> signInResult;
  final changes = StreamController<bool>.broadcast();
  @override
  bool get hasSession => session;
  @override
  Stream<bool> get signedInChanges => changes.stream;
  @override
  Future<Result<void>> signInWithGoogle() async {
    if (signInResult is Ok) {
      session = true;
      changes.add(true);
    }
    return signInResult;
  }

  @override
  Future<Result<bool>> activateSession() async => Ok(allowed);
  @override
  Future<Result<Member>> currentMember() async =>
      const Ok(Member(userId: 'u1', displayName: 'Maya'));
  @override
  Future<void> signOut() async {
    session = false;
    changes.add(false);
  }
}

class FakeUpdate implements UpdateRepository {
  FakeUpdate({
    this.installed = 105,
    this.min = const Ok(1),
    this.play = const Ok(null),
  });

  int installed;
  Result<int> min;
  Result<int?> play;
  final calls = <String>[];
  bool failFlexible = false;
  bool failImmediate = false;

  @override
  Future<int> installedBuild() async => installed;
  @override
  Future<Result<int>> minSupportedBuild() async => min;
  @override
  Future<Result<int?>> availablePlayBuild() async => play;
  @override
  Future<void> startFlexibleUpdate() async {
    calls.add('flexible');
    if (failFlexible) throw StateError('declined');
  }

  @override
  Future<void> completeFlexibleUpdate() async => calls.add('complete');
  @override
  Future<void> startImmediateUpdate() async {
    calls.add('immediate');
    if (failImmediate) throw StateError('unavailable');
  }

  @override
  Future<void> openStoreListing() async => calls.add('store');
}

class FakeChat implements ChatRepository {
  FakeChat({this.list = const [], this.initial = const []});

  List<Conversation> list;
  List<Message> initial;
  Result<List<Conversation>>? conversationsResult;
  Result<List<Message>>? messagesResult;
  Result<Message>? sendResult;
  Result<String> startResult = const Ok('c-new');

  /// When set, messages() waits on it, so a test can deliver a Realtime
  /// message while the initial read is still in flight.
  Completer<void>? gate;

  final sent = <String>[];
  final started = <String>[];
  int subscriptions = 0;
  final _incoming = StreamController<Message>.broadcast();

  /// Pushes a message as if Realtime delivered it.
  void deliver(Message m) => _incoming.add(m);

  List<Member> memberList = const [];
  Result<List<Member>>? membersResult;

  @override
  Future<Result<List<Member>>> members() async =>
      membersResult ?? Ok(memberList);

  @override
  Future<Result<List<Conversation>>> conversations() async =>
      conversationsResult ?? Ok(list);

  @override
  Future<Result<List<Message>>> messages(String conversationId) async {
    if (gate != null) await gate!.future;
    return messagesResult ?? Ok(initial);
  }

  @override
  Future<Result<Message>> send({
    required String conversationId,
    required String body,
  }) async {
    sent.add(body);
    return sendResult ??
        Ok(
          Message(
            id: 'sent-${sent.length}',
            conversationId: conversationId,
            senderId: 'me',
            body: body.trim(),
            createdAt: DateTime.now(),
          ),
        );
  }

  @override
  Future<Result<Stream<Message>>> incoming(String conversationId) async {
    subscriptions++;
    return Ok(
      _incoming.stream.transform(
        StreamTransformer<Message, Message>.fromHandlers(
          handleData: (m, sink) {
            if (m.conversationId == conversationId) sink.add(m);
          },
        ),
      ),
    );
  }

  @override
  Future<Result<String>> startDirectConversation(String otherUserId) async {
    started.add(otherUserId);
    return startResult;
  }

  /// Every group asked for, in order, exactly as the caller passed it.
  final groups = <({String title, List<String> memberIds})>[];

  /// Forces the outcome. Left null the fake answers like the RPC: it refuses
  /// what the database refuses, and a group is NEVER reused — every accepted
  /// call returns a new id.
  Result<String>? groupResult;
  int _groupSeq = 0;

  final renames = <String>[];
  Result<void>? renameResult;

  @override
  Future<Result<String>> startGroupConversation({
    required String title,
    required List<String> memberIds,
  }) async {
    groups.add((title: title, memberIds: List.unmodifiable(memberIds)));
    if (groupResult case final forced?) return forced;
    final trimmed = title.trim();
    if (trimmed.isEmpty || trimmed.length > 80) {
      return const Err(ProviderFailure('a group needs a name'));
    }
    if (memberIds.isEmpty) {
      return const Err(ProviderFailure('a group needs another member'));
    }
    return Ok('g${++_groupSeq}');
  }

  @override
  Future<Result<void>> setDisplayName(String displayName) async {
    renames.add(displayName);
    if (renameResult case final forced?) return forced;
    final trimmed = displayName.trim();
    if (trimmed.isEmpty || trimmed.length > 80) {
      return const Err(ProviderFailure('a display name is 1 to 80 characters'));
    }
    return const Ok(null);
  }
}

/// A chat repository written from the [ChatRepository] contract, for the
/// widget and controller tests that must survive inconvenient reality.
///
/// Deliberately not a convenience stub: a subscription is not confirmed until
/// the test confirms it, a read can be held open while other things happen,
/// Realtime delivers only to a live subscription, and every call is recorded
/// in order so "subscribe before you read" can be checked.
class ChatFake implements ChatRepository {
  ChatFake({this.latency = Duration.zero});

  /// Every call takes at least this long; nothing here is ever synchronous.
  final Duration latency;

  Result<List<Member>> membersResult = const Ok(<Member>[]);
  Result<List<Conversation>> conversationsResult = const Ok(<Conversation>[]);
  Result<List<Message>> messagesResult = const Ok(<Message>[]);
  Result<Message>? sendResult;
  Result<String> startResult = const Ok('c-new');

  /// Call names in the order they were made, e.g. `incoming:c1`.
  final calls = <String>[];
  final sent = <({String conversationId, String body})>[];
  final started = <String>[];
  int subscriptions = 0;
  int canceledSubscriptions = 0;

  Completer<void>? _read;
  Completer<void>? _subscribe;
  final _streams = <String, StreamController<Message>>{};

  /// Leaves the next [messages] read in flight until [releaseMessages].
  void holdMessages() => _read = Completer<void>();
  void releaseMessages() {
    _read?.complete();
    _read = null;
  }

  /// The server has not confirmed the subscription yet. Realtime is never
  /// instantly ready, and code that assumes it is must fail here.
  void holdSubscription() => _subscribe = Completer<void>();
  void confirmSubscription() {
    _subscribe?.complete();
    _subscribe = null;
  }

  /// Delivers [m] the way Realtime would: to a live subscription only.
  /// Anything sent while nobody is listening is gone, exactly as on the wire.
  void deliver(Message m) => _streams[m.conversationId]?.add(m);

  Future<void> _tick(String call) async {
    calls.add(call);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
  }

  @override
  Future<Result<List<Member>>> members() async {
    await _tick('members');
    return membersResult;
  }

  @override
  Future<Result<List<Conversation>>> conversations() async {
    await _tick('conversations');
    return conversationsResult;
  }

  @override
  Future<Result<List<Message>>> messages(String conversationId) async {
    await _tick('messages:$conversationId');
    if (_read != null) await _read!.future;
    return messagesResult;
  }

  @override
  Future<Result<Message>> send({
    required String conversationId,
    required String body,
  }) async {
    await _tick('send:$conversationId');
    sent.add((conversationId: conversationId, body: body));
    return sendResult ??
        Ok(
          Message(
            id: 'sent-${sent.length}',
            conversationId: conversationId,
            senderId: 'me',
            body: body.trim(),
            createdAt: DateTime.now(),
          ),
        );
  }

  /// When set, incoming() reports a connection that cannot be established.
  Result<Stream<Message>>? incomingResult;

  @override
  Future<Result<Stream<Message>>> incoming(String conversationId) async {
    await _tick('incoming:$conversationId');
    if (_subscribe != null) await _subscribe!.future;
    if (incomingResult case final failed?) return failed;
    subscriptions++;
    final controller = _streams[conversationId] ??=
        StreamController<Message>.broadcast(
          onCancel: () => canceledSubscriptions++,
        );
    return Ok(controller.stream);
  }

  @override
  Future<Result<String>> startDirectConversation(String otherUserId) async {
    await _tick('start:$otherUserId');
    started.add(otherUserId);
    return startResult;
  }

  /// Every group asked for, in order, exactly as the caller passed it —
  /// including a caller that lists itself or the same invitee twice.
  final groups = <({String title, List<String> memberIds})>[];

  /// Forces the outcome. Left null the fake answers like the RPC: the same
  /// refusals the database makes, and a NEW conversation every time, because
  /// unlike a 1:1 a group is never reused. An accepted group also joins
  /// [conversationsResult], so a list that does not re-read cannot fake it.
  Result<String>? groupResult;
  int _groupSeq = 0;

  final renames = <String>[];
  Result<void>? renameResult;

  @override
  Future<Result<String>> startGroupConversation({
    required String title,
    required List<String> memberIds,
  }) async {
    await _tick('group:$title');
    groups.add((title: title, memberIds: List.unmodifiable(memberIds)));
    if (groupResult case final forced?) return forced;
    final trimmed = title.trim();
    if (trimmed.isEmpty || trimmed.length > 80) {
      return const Err(ProviderFailure('a group needs a name'));
    }
    if (memberIds.isEmpty) {
      return const Err(ProviderFailure('a group needs another member'));
    }
    final id = 'g${++_groupSeq}';
    if (conversationsResult case Ok(value: final existing)) {
      conversationsResult = Ok([
        Conversation(id: id, title: trimmed),
        ...existing,
      ]);
    }
    return Ok(id);
  }

  @override
  Future<Result<void>> setDisplayName(String displayName) async {
    await _tick('rename:$displayName');
    renames.add(displayName);
    if (renameResult case final forced?) return forced;
    final trimmed = displayName.trim();
    if (trimmed.isEmpty || trimmed.length > 80) {
      return const Err(ProviderFailure('a display name is 1 to 80 characters'));
    }
    return const Ok(null);
  }
}
