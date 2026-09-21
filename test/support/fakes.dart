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
  Result<void> sendResult = const Ok(null);
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

  @override
  Future<Result<List<Conversation>>> conversations() async =>
      conversationsResult ?? Ok(list);

  @override
  Future<Result<List<Message>>> messages(String conversationId) async {
    if (gate != null) await gate!.future;
    return messagesResult ?? Ok(initial);
  }

  @override
  Future<Result<void>> send({
    required String conversationId,
    required String body,
  }) async {
    sent.add(body);
    return sendResult;
  }

  @override
  Future<Stream<Message>> incoming(String conversationId) async {
    subscriptions++;
    return _incoming.stream.transform(
      StreamTransformer<Message, Message>.fromHandlers(
        handleData: (m, sink) {
          if (m.conversationId == conversationId) sink.add(m);
        },
      ),
    );
  }

  @override
  Future<Result<String>> startDirectConversation(String otherUserId) async {
    started.add(otherUserId);
    return startResult;
  }
}
