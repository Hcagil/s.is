// Hand-written fakes shared by controller and widget tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/gallery.dart';
import 'package:sis/features/chat/domain/links.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/chat/domain/read_marks.dart';
import 'package:sis/features/notifications/domain/notification_settings.dart';
import 'package:sis/features/notifications/domain/push.dart';
import 'package:sis/features/presence/domain/presence_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/domain/profile_repository.dart';
import 'package:sis/features/update/domain/update_repository.dart';

/// Waits for the session to settle on a member, as the app does: nothing
/// opens a conversation or reads a list before the member is allowed. A test
/// that does so first watches the account change from nobody to the member,
/// which rebuilds every per-account provider — something the app never does.
Future<ProviderContainer> settled(ProviderContainer c) async {
  await c.read(sessionControllerProvider.future);
  if (c.read(currentUserIdProvider) == null) {
    throw StateError('the session did not settle on an allowed member');
  }
  return c;
}

class FakeAuth implements AuthRepository {
  FakeAuth({
    this.session = false,
    this.allowed = true,
    this.signInResult = const Ok(null),
    this.member = const Member(userId: 'u1', displayName: 'Maya'),
  });
  bool session;
  bool allowed;
  Result<void> signInResult;

  /// Who currentMember() reports: the signed-in account, email included.
  Member member;

  /// Runs as signOut() is entered, before the session ends.
  void Function()? onSignOut;
  int signOuts = 0;
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
  Future<Result<Member>> currentMember() async => Ok(member);
  @override
  Future<void> signOut() async {
    signOuts++;
    onSignOut?.call();
    await Future<void>.delayed(Duration.zero); // a real sign-out is a call
    session = false;
    changes.add(false);
  }
}

/// Auth whose session check is not a plain yes/no: it can fail (offline at
/// start) or stay in flight until the test answers it, as a slow network
/// does.
class CheckingAuth extends FakeAuth {
  CheckingAuth({super.session, super.member});

  /// What the next activateSession() answers; null = [allowed].
  Result<bool>? answer;
  Completer<void>? _gate;

  /// The next activateSession() stays in flight until [answerNow].
  void hold() => _gate = Completer<void>();
  void answerNow() {
    _gate?.complete();
    _gate = null;
  }

  @override
  Future<Result<bool>> activateSession() async {
    await Future<void>.value(); // a network call: never answers in-line
    final gate = _gate;
    if (gate != null) await gate.future;
    return answer ?? Ok(allowed);
  }
}

/// Play and the policy table, as the controller sees them. Every call is
/// asynchronous, as the real ones are; [flexibleGate] holds a flexible
/// download "in flight" until the test completes it, and a finished download
/// is then reported by [checkForUpdate] as Play reports it: downloaded.
class FakeUpdate implements UpdateRepository {
  FakeUpdate({
    this.installed = 105,
    this.version = '0.6.0',
    this.min = const Ok(1),
    this.play = const Ok(PlayUpdateCheck()),
  });

  int installed;
  String version;
  Result<int> min;
  Result<PlayUpdateCheck> play;
  final calls = <String>[];
  bool failFlexible = false;
  bool failImmediate = false;

  /// How many times Play was asked.
  int checks = 0;

  /// How many times the minimum supported build was read.
  int minReads = 0;

  /// When set, checkForUpdate() waits on it (Play has not answered yet).
  Completer<void>? checkGate;

  /// When set, startFlexibleUpdate() waits on it (the download is running).
  Completer<void>? flexibleGate;

  /// Offers [build] as a flexible update from now on.
  void offer(int build) => play = Ok(PlayUpdateCheck(offeredBuild: build));

  @override
  Future<int> installedBuild() async => installed;
  @override
  Future<String> installedVersion() async => version;
  @override
  Future<Result<int>> minSupportedBuild() async {
    minReads++;
    await Future<void>.delayed(Duration.zero);
    return min;
  }

  @override
  Future<Result<PlayUpdateCheck>> checkForUpdate() async {
    checks++;
    await Future<void>.delayed(Duration.zero);
    await checkGate?.future;
    return play;
  }

  @override
  Future<void> startFlexibleUpdate() async {
    calls.add('flexible');
    if (failFlexible) throw StateError('declined');
    await flexibleGate?.future;
    final offered = switch (play) {
      Ok(:final value) => value.offeredBuild,
      Err() => null,
    };
    play = Ok(PlayUpdateCheck(offeredBuild: offered, downloaded: true));
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

  /// The replyTo handed to each [send], in the same order as [sent].
  final sentReplyTo = <String?>[];
  final started = <String>[];
  int subscriptions = 0;
  final _incoming = StreamController<Message>.broadcast();
  final _all = StreamController<Message>.broadcast();

  /// Pushes a message as if Realtime delivered it: to the conversation's own
  /// subscription AND to every list-wide one, as one insert reaches both.
  void deliver(Message m) {
    _incoming.add(m);
    _all.add(m);
  }

  /// When set, incomingAll() reports a subscription that could not be made.
  Result<Stream<Message>>? incomingAllResult;

  /// When set, incomingAll() is not confirmed until it completes.
  Completer<void>? allGate;

  /// When set, conversations() waits on it: the list read held in flight.
  Completer<void>? listGate;
  int allSubscriptions = 0;
  int listReads = 0;

  List<Member> memberList = const [];
  Result<List<Member>>? membersResult;

  @override
  Future<Result<List<Member>>> members() async =>
      membersResult ?? Ok(memberList);

  Result<List<Member>> conversationMembersResult = const Ok(<Member>[]);
  Result<List<Message>> sharedMediaResult = const Ok(<Message>[]);
  Result<List<Message>> sharedLinksResult = const Ok(<Message>[]);

  @override
  Future<Result<List<Member>>> conversationMembers(String id) async =>
      conversationMembersResult;
  @override
  Future<Result<List<Message>>> sharedMedia(String id) async =>
      sharedMediaResult;
  @override
  Future<Result<List<Message>>> sharedLinks(String id) async =>
      sharedLinksResult;

  @override
  Future<Result<List<Conversation>>> conversations() async {
    listReads++;
    if (listGate != null) await listGate!.future;
    return conversationsResult ?? Ok(list);
  }

  /// Every conversation [markRead] was called for, in order.
  final markedRead = <String>[];
  Result<void> markReadResult = const Ok(null);

  @override
  Future<Result<void>> markRead(String conversationId) async {
    markedRead.add(conversationId);
    return markReadResult;
  }

  @override
  Future<Result<List<Message>>> messages(String conversationId) async {
    if (gate != null) await gate!.future;
    return messagesResult ?? Ok(initial);
  }

  @override
  Future<Result<Message>> send({
    required String conversationId,
    required String body,
    String? replyTo,
  }) async {
    sent.add(body);
    sentReplyTo.add(replyTo);
    return sendResult ??
        Ok(
          Message(
            id: 'sent-${sent.length}',
            conversationId: conversationId,
            senderId: 'me',
            body: body.trim(),
            createdAt: DateTime.now(),
            replyTo: replyTo,
          ),
        );
  }

  @override
  Future<Result<Stream<Message>>> incomingAll() async {
    if (allGate != null) await allGate!.future;
    if (incomingAllResult case final failed?) return failed;
    allSubscriptions++;
    return Ok(_all.stream);
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

  /// Every image handed to [sendImage], with the caption it was sent with.
  final sentImages =
      <
        ({
          String conversationId,
          PickedImage image,
          String body,
          String? replyTo,
        })
      >[];

  /// Every path [attachmentUrl] was asked to sign, in order.
  final urlRequests = <String>[];

  /// Keys this fake has actually stored. A path it never stored cannot be
  /// signed, exactly as the bucket refuses to sign an object the caller may
  /// not read. Seed it with [store] when a test invents history.
  final storedObjects = <String>{};

  /// The bytes actually behind each stored path, as a real receiver would
  /// download them. [sendImage] records the sender's own bytes here.
  final objectBytes = <String, Uint8List>{};
  void store(String path, [Uint8List? bytes]) {
    storedObjects.add(path);
    if (bytes != null) objectBytes[path] = bytes;
  }

  /// Force an outcome. Left null both calls answer like the real thing: the
  /// upload refuses what the bucket and the check constraint refuse, and a
  /// URL is issued only for a stored key.
  Result<Message>? sendImageResult;
  Result<Uri>? attachmentUrlResult;
  Result<Uint8List>? attachmentBytesResult;

  /// Every path [attachmentBytes] was asked for, in order.
  final bytesRequests = <String>[];

  int _imageSeq = 0;

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
    String? replyTo,
  }) async {
    sentImages.add((
      conversationId: conversationId,
      image: image,
      body: body,
      replyTo: replyTo,
    ));
    if (sendImageResult case final forced?) return forced;
    if (rejectUpload(image, body) case final refused?) return refused;
    final path = '$conversationId/${++_imageSeq}.${image.extension}';
    storedObjects.add(path);
    objectBytes[path] = image.bytes;
    return Ok(
      Message(
        id: 'img-$_imageSeq',
        conversationId: conversationId,
        senderId: 'me',
        body: body.trim(),
        createdAt: DateTime.now(),
        attachmentPath: path,
        attachmentPreview: image.preview,
        replyTo: replyTo,
      ),
    );
  }

  /// Every forward asked for, in order: which message, to which conversations.
  final forwarded = <({String messageId, List<String> conversationIds})>[];

  /// Forces the outcome. Left null the fake answers like the server: one new
  /// message per target conversation, marked forwarded, its photo (if any)
  /// copied to a brand NEW path in that target's own folder -- the source
  /// object and message untouched -- delivered live the way an insert
  /// really arrives.
  Result<void>? forwardResult;
  int _forwardSeq = 0;

  @override
  Future<Result<void>> forward(
    Message message,
    List<String> conversationIds,
  ) async {
    forwarded.add((
      messageId: message.id,
      conversationIds: List.unmodifiable(conversationIds),
    ));
    if (forwardResult case final forced?) return forced;
    for (final id in conversationIds) {
      String? path;
      final source = message.attachmentPath;
      if (source != null) {
        path = '$id/fwd-${++_forwardSeq}.${source.split('.').last}';
        storedObjects.add(path);
        final bytes = objectBytes[source];
        if (bytes != null) objectBytes[path] = bytes;
      }
      deliver(
        Message(
          id: 'fwd-${++_forwardSeq}',
          conversationId: id,
          senderId: 'me',
          body: message.body,
          createdAt: DateTime.now(),
          attachmentPath: path,
          attachmentPreview: message.attachmentPreview,
          forwarded: true,
        ),
      );
    }
    return const Ok(null);
  }

  @override
  Future<Result<Uri>> attachmentUrl(String attachmentPath) async {
    urlRequests.add(attachmentPath);
    if (attachmentUrlResult case final forced?) return forced;
    if (!storedObjects.contains(attachmentPath)) {
      return const Err(DeniedFailure());
    }
    // Shaped like the real one: single use, expires, and not guessable.
    return Ok(
      Uri.parse(
        'https://storage.test/object/sign/attachments/$attachmentPath'
        '?token=fake&expires=3600',
      ),
    );
  }

  @override
  Future<Result<Uint8List>> attachmentBytes(String attachmentPath) async {
    bytesRequests.add(attachmentPath);
    if (attachmentBytesResult case final forced?) return forced;
    if (!storedObjects.contains(attachmentPath)) {
      return const Err(DeniedFailure());
    }
    return Ok(objectBytes[attachmentPath] ?? pngBytes);
  }

  /// Every message handed to [deleteForEveryone], in order.
  final deletedMessages = <Message>[];

  /// Forces the outcome. Left null the fake answers like the server: it wipes
  /// the message and delivers the update the way Realtime does -- vanished
  /// under an hour old, a placeholder otherwise -- to both the conversation's
  /// own subscription and the list-wide one.
  Result<void>? deleteForEveryoneResult;

  @override
  Future<Result<void>> deleteForEveryone(Message message) async {
    deletedMessages.add(message);
    if (deleteForEveryoneResult case final forced?) return forced;
    final vanished =
        DateTime.now().difference(message.createdAt) < const Duration(hours: 1);
    deliver(
      Message(
        id: message.id,
        conversationId: message.conversationId,
        senderId: message.senderId,
        body: '',
        createdAt: message.createdAt,
        deletion: vanished
            ? MessageDeletion.vanished
            : MessageDeletion.placeholder,
      ),
    );
    return const Ok(null);
  }

  @override
  Future<Result<List<ReadMark>>> readMarks(String conversationId) async =>
      const Ok([]);
  @override
  Future<Result<Stream<ReadMark>>> readUpdates(String conversationId) async =>
      Ok(const Stream<ReadMark>.empty());
}

/// A chat repository written from the [ChatRepository] contract, for the
/// widget and controller tests that must survive inconvenient reality.
///
/// Deliberately not a convenience stub: a subscription is not confirmed until
/// the test confirms it, a read can be held open while other things happen,
/// Realtime delivers only to a live subscription, and every call is recorded
/// in order so "subscribe before you read" can be checked.
class ChatFake implements ChatRepository {
  ChatFake({this.latency = Duration.zero, this.self});

  /// Every call takes at least this long; nothing here is ever synchronous.
  final Duration latency;

  /// The signed-in member, as the server knows them. When set, [deliver] also
  /// writes to the "database" behind [conversations], the way an insert
  /// does: the preview moves, and every member but the sender has one more
  /// unread. Left null the database is whatever [conversationsResult] says.
  final String? self;

  Result<List<Member>> membersResult = const Ok(<Member>[]);
  Result<List<Conversation>> conversationsResult = const Ok(<Conversation>[]);
  Result<List<Message>> messagesResult = const Ok(<Message>[]);
  Result<Message>? sendResult;
  Result<String> startResult = const Ok('c-new');

  /// Call names in the order they were made, e.g. `incoming:c1`.
  final calls = <String>[];
  final sent = <({String conversationId, String body, String? replyTo})>[];
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
  /// One insert reaches the conversation's own subscription and every
  /// list-wide one ([incomingAll]) alike.
  void deliver(Message m) {
    if (self != null) _store(m);
    history[m.conversationId]?.add(m);
    _streams[m.conversationId]?.add(m);
    _all?.add(m);
  }

  void _store(Message m) {
    final current = conversationsResult;
    if (current is! Ok<List<Conversation>>) return;
    final rows = [
      for (final c in current.value)
        if (c.id != m.conversationId)
          c
        else
          Conversation(
            id: c.id,
            title: c.title,
            other: c.other,
            lastMessage: m.body,
            lastMessageAt: m.createdAt,
            lastSenderId: m.senderId,
            unread: m.senderId == self ? c.unread : c.unread + 1,
          ),
    ];
    rows.sort((a, b) {
      final x = a.lastMessageAt, y = b.lastMessageAt;
      if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
      return y.compareTo(x);
    });
    conversationsResult = Ok(rows);
  }

  /// Every conversation [markRead] was called for, in order.
  final markedRead = <String>[];

  /// Forces the outcome. Left null the fake answers like the RPC: a
  /// conversation the member is not in is refused, and otherwise only this
  /// member's count goes to zero -- which the next [conversations] reflects.
  Result<void>? markReadResult;

  Completer<void>? _markRead;

  /// Leaves the next [markRead] in flight until [releaseMarkRead]: the screen
  /// can be gone, and the list disposed, before the server answers.
  void holdMarkRead() => _markRead = Completer<void>();
  void releaseMarkRead() {
    _markRead?.complete();
    _markRead = null;
  }

  @override
  Future<Result<void>> markRead(String conversationId) async {
    await _tick('markRead:$conversationId');
    markedRead.add(conversationId);
    final held = _markRead;
    if (held != null) await held.future;
    if (markReadResult case final forced?) return forced;
    final current = conversationsResult;
    if (current is! Ok<List<Conversation>>) return const Ok(null);
    if (!current.value.any((c) => c.id == conversationId)) {
      return const Err(DeniedFailure());
    }
    conversationsResult = Ok([
      for (final c in current.value)
        if (c.id != conversationId)
          c
        else
          Conversation(
            id: c.id,
            title: c.title,
            other: c.other,
            lastMessage: c.lastMessage,
            lastMessageAt: c.lastMessageAt,
            lastSenderId: c.lastSenderId,
          ),
    ]);
    return const Ok(null);
  }

  Completer<void>? _subscribeAll;
  Completer<void>? _readList;
  StreamController<Message>? _all;
  int allSubscriptions = 0;
  int canceledAllSubscriptions = 0;

  /// The list-wide subscription is not confirmed until [confirmAllSubscription].
  void holdAllSubscription() => _subscribeAll = Completer<void>();
  void confirmAllSubscription() {
    _subscribeAll?.complete();
    _subscribeAll = null;
  }

  /// Leaves the next [conversations] read in flight until [releaseList].
  void holdList() => _readList = Completer<void>();
  void releaseList() {
    _readList?.complete();
    _readList = null;
  }

  Future<void> _tick(String call) async {
    calls.add(call);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
  }

  @override
  Future<Result<List<Member>>> members() async {
    await _tick('members');
    final held = _people;
    if (held != null) await held.future;
    return membersResult;
  }

  /// Who is in each conversation, as conversation_members joined to profiles
  /// holds it. A conversation the caller is not in has no entry and reads as
  /// empty -- row-level security hides rows, it does not raise.
  final roster = <String, List<Member>>{};

  /// Each conversation's history, oldest first, as the table holds it. When a
  /// conversation has an entry, [messages] answers from it (and [deliver]
  /// appends to it), so two conversations can hold different messages.
  final history = <String, List<Message>>{};

  /// Force an outcome; left null each read answers from [roster]/[history]
  /// with the contract's filter, order and cap.
  Result<List<Member>>? conversationMembersResult;
  Result<List<Message>>? sharedMediaResult;
  Result<List<Message>>? sharedLinksResult;

  Completer<void>? _people;
  Completer<void>? _shared;

  /// [members] and [conversationMembers] stay in flight until [releasePeople].
  void holdPeople() => _people = Completer<void>();
  void releasePeople() {
    _people?.complete();
    _people = null;
  }

  /// [sharedMedia] and [sharedLinks] stay in flight until [releaseShared].
  void holdShared() => _shared = Completer<void>();
  void releaseShared() {
    _shared?.complete();
    _shared = null;
  }

  static final _webAddress = RegExp(r'https?://|www\.', caseSensitive: false);

  List<Message> _newest(String id, bool Function(Message) keep) =>
      [...(history[id] ?? const <Message>[]).where(keep)].reversed
          .take(500)
          .toList();

  @override
  Future<Result<List<Member>>> conversationMembers(String id) async {
    await _tick('conversationMembers:$id');
    final held = _people;
    if (held != null) await held.future;
    if (conversationMembersResult case final forced?) return forced;
    return Ok(
      [...?roster[id]]..sort((a, b) => a.displayName.compareTo(b.displayName)),
    );
  }

  @override
  Future<Result<List<Message>>> sharedMedia(String id) async {
    await _tick('sharedMedia:$id');
    final held = _shared;
    if (held != null) await held.future;
    if (sharedMediaResult case final forced?) return forced;
    return Ok(_newest(id, (m) => m.hasAttachment));
  }

  @override
  Future<Result<List<Message>>> sharedLinks(String id) async {
    await _tick('sharedLinks:$id');
    final held = _shared;
    if (held != null) await held.future;
    if (sharedLinksResult case final forced?) return forced;
    return Ok(_newest(id, (m) => _webAddress.hasMatch(m.body)));
  }

  @override
  Future<Result<List<Conversation>>> conversations() async {
    // The answer is the database as it stood when the query ran; anything
    // that changes while the read is held open is not in it.
    final snapshot = conversationsResult;
    await _tick('conversations');
    final held = _readList;
    if (held != null) await held.future;
    return snapshot;
  }

  @override
  Future<Result<List<Message>>> messages(String conversationId) async {
    await _tick('messages:$conversationId');
    if (_read != null) await _read!.future;
    if (history[conversationId] case final rows?) return Ok(List.of(rows));
    return messagesResult;
  }

  @override
  Future<Result<Message>> send({
    required String conversationId,
    required String body,
    String? replyTo,
  }) async {
    await _tick('send:$conversationId');
    sent.add((conversationId: conversationId, body: body, replyTo: replyTo));
    return sendResult ??
        Ok(
          Message(
            id: 'sent-${sent.length}',
            conversationId: conversationId,
            senderId: 'me',
            body: body.trim(),
            createdAt: DateTime.now(),
            replyTo: replyTo,
          ),
        );
  }

  /// When set, incoming() reports a connection that cannot be established.
  Result<Stream<Message>>? incomingResult;

  /// When set, incomingAll() reports a subscription that cannot be made.
  Result<Stream<Message>>? incomingAllResult;

  @override
  Future<Result<Stream<Message>>> incomingAll() async {
    await _tick('incomingAll');
    final held = _subscribeAll;
    if (held != null) await held.future;
    if (incomingAllResult case final failed?) return failed;
    allSubscriptions++;
    final controller = _all ??= StreamController<Message>.broadcast(
      onCancel: () => canceledAllSubscriptions++,
    );
    return Ok(controller.stream);
  }

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

  /// Every image handed to [sendImage], with the caption it was sent with.
  final sentImages =
      <
        ({
          String conversationId,
          PickedImage image,
          String body,
          String? replyTo,
        })
      >[];

  /// Every path [attachmentUrl] was asked to sign, in order.
  final urlRequests = <String>[];

  /// Keys this fake has actually stored. A path it never stored cannot be
  /// signed, exactly as the bucket refuses to sign an object the caller may
  /// not read. Seed it with [store] when a test invents history.
  final storedObjects = <String>{};

  /// The bytes actually behind each stored path, as a real receiver would
  /// download them. [sendImage] records the sender's own bytes here, so a
  /// receiver reading the same path back sees what was actually sent.
  final objectBytes = <String, Uint8List>{};
  void store(String path, [Uint8List? bytes]) {
    storedObjects.add(path);
    if (bytes != null) objectBytes[path] = bytes;
  }

  /// Force an outcome. Left null both calls answer like the real thing: the
  /// upload refuses what the bucket and the check constraint refuse, and a
  /// URL is issued only for a stored key.
  Result<Message>? sendImageResult;
  Result<Uri>? attachmentUrlResult;
  Result<Uint8List>? attachmentBytesResult;

  /// Per-path refusals, for a conversation where one object cannot be signed
  /// while its neighbours can.
  final urlFailures = <String, Failure>{};
  final bytesFailures = <String, Failure>{};

  /// Every path [attachmentBytes] was asked for, in order.
  final bytesRequests = <String>[];

  Completer<void>? _bytesHold;

  /// The next [attachmentBytes] call stays in flight until [releaseBytes]: a
  /// slow connection, independent of every other call's own latency.
  void holdBytes() => _bytesHold = Completer<void>();
  void releaseBytes() {
    _bytesHold?.complete();
    _bytesHold = null;
  }

  int _imageSeq = 0;

  Completer<void>? _sendImageHold;

  /// The next [sendImage] stays in flight until [releaseSendImage]: an
  /// upload is never instant, and a test needs the moment before the
  /// repository answers to see whatever the caller shows in the meantime.
  void holdSendImage() => _sendImageHold = Completer<void>();
  void releaseSendImage() {
    _sendImageHold?.complete();
    _sendImageHold = null;
  }

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
    String? replyTo,
  }) async {
    await _tick('sendImage:$conversationId');
    sentImages.add((
      conversationId: conversationId,
      image: image,
      body: body,
      replyTo: replyTo,
    ));
    final held = _sendImageHold;
    if (held != null) await held.future;
    if (sendImageResult case final forced?) return forced;
    if (rejectUpload(image, body) case final refused?) return refused;
    final path = '$conversationId/${++_imageSeq}.${image.extension}';
    storedObjects.add(path);
    objectBytes[path] = image.bytes;
    return Ok(
      Message(
        id: 'img-$_imageSeq',
        conversationId: conversationId,
        senderId: 'me',
        body: body.trim(),
        createdAt: DateTime.now(),
        attachmentPath: path,
        attachmentPreview: image.preview,
        replyTo: replyTo,
      ),
    );
  }

  /// Every forward asked for, in order: which message, to which conversations.
  final forwarded = <({String messageId, List<String> conversationIds})>[];

  /// Forces the outcome. Left null the fake answers like the server: refused
  /// whole -- before creating anything -- if any target is not one the
  /// caller belongs to (per [conversationsResult]); otherwise one new,
  /// forwarded message per target, its photo (if any) copied to a brand NEW
  /// path in that target's own folder, the source object and message
  /// untouched, delivered live the way an insert really arrives.
  Result<void>? forwardResult;
  int _forwardSeq = 0;

  @override
  Future<Result<void>> forward(
    Message message,
    List<String> conversationIds,
  ) async {
    await _tick('forward:${message.id}');
    forwarded.add((
      messageId: message.id,
      conversationIds: List.unmodifiable(conversationIds),
    ));
    if (forwardResult case final forced?) return forced;
    final mine = {
      for (final c in switch (conversationsResult) {
        Ok(:final value) => value,
        Err() => const <Conversation>[],
      })
        c.id,
    };
    for (final id in conversationIds) {
      if (!mine.contains(id)) return const Err(DeniedFailure());
    }
    for (final id in conversationIds) {
      String? path;
      final source = message.attachmentPath;
      if (source != null) {
        path = '$id/fwd-${++_forwardSeq}.${source.split('.').last}';
        storedObjects.add(path);
        final bytes = objectBytes[source];
        if (bytes != null) objectBytes[path] = bytes;
      }
      deliver(
        Message(
          id: 'fwd-${++_forwardSeq}',
          conversationId: id,
          senderId: self ?? 'me',
          body: message.body,
          createdAt: DateTime.now(),
          attachmentPath: path,
          attachmentPreview: message.attachmentPreview,
          forwarded: true,
        ),
      );
    }
    return const Ok(null);
  }

  @override
  Future<Result<Uri>> attachmentUrl(String attachmentPath) async {
    await _tick('attachmentUrl:$attachmentPath');
    urlRequests.add(attachmentPath);
    if (urlFailures[attachmentPath] case final failure?) return Err(failure);
    if (attachmentUrlResult case final forced?) return forced;
    if (!storedObjects.contains(attachmentPath)) {
      return const Err(DeniedFailure());
    }
    // Shaped like the real one: single use, expires, and not guessable.
    return Ok(
      Uri.parse(
        'https://storage.test/object/sign/attachments/$attachmentPath'
        '?token=fake&expires=3600',
      ),
    );
  }

  @override
  Future<Result<Uint8List>> attachmentBytes(String attachmentPath) async {
    await _tick('attachmentBytes:$attachmentPath');
    bytesRequests.add(attachmentPath);
    final held = _bytesHold;
    if (held != null) await held.future;
    if (bytesFailures[attachmentPath] case final failure?) return Err(failure);
    if (attachmentBytesResult case final forced?) return forced;
    if (!storedObjects.contains(attachmentPath)) {
      return const Err(DeniedFailure());
    }
    return Ok(objectBytes[attachmentPath] ?? pngBytes);
  }

  /// Every message id [deleteForEveryone] was asked to delete, in order.
  final deleted = <String>[];

  /// Forces the outcome. Left null the fake answers like the server: refused
  /// (DeniedFailure) unless the message is in [history], sent by [self]
  /// (when set) or its own recorded sender, and not already deleted -- then
  /// wipes it (vanished under an hour old, a placeholder otherwise) and
  /// delivers the update to that conversation's subscription AND the
  /// list-wide one, exactly like a real UPDATE over Realtime.
  Result<void>? deleteForEveryoneResult;

  @override
  Future<Result<void>> deleteForEveryone(Message message) async {
    await _tick('delete:${message.id}');
    deleted.add(message.id);
    if (deleteForEveryoneResult case final forced?) return forced;
    final rows = history[message.conversationId];
    final i = rows?.indexWhere((m) => m.id == message.id) ?? -1;
    if (rows == null || i < 0) return const Err(DeniedFailure());
    final existing = rows[i];
    if (existing.isDeleted ||
        (self != null && existing.senderId != self) ||
        DateTime.now().difference(existing.createdAt) >
            const Duration(hours: 6)) {
      return const Err(DeniedFailure());
    }
    final vanished =
        DateTime.now().difference(existing.createdAt) <
        const Duration(hours: 1);
    final wiped = Message(
      id: existing.id,
      conversationId: existing.conversationId,
      senderId: existing.senderId,
      body: '',
      createdAt: existing.createdAt,
      deletion: vanished
          ? MessageDeletion.vanished
          : MessageDeletion.placeholder,
    );
    rows[i] = wiped;
    _streams[message.conversationId]?.add(wiped);
    _all?.add(wiped);
    return const Ok(null);
  }

  /// What [readMarks] answers with, per conversation, when
  /// [readMarksResult] is not forced.
  final readMarksData = <String, List<ReadMark>>{};

  /// Forces the outcome for every conversation. Left null each call answers
  /// from [readMarksData] (empty when the conversation has no entry).
  Result<List<ReadMark>>? readMarksResult;

  /// Every conversation [readMarks] was asked for, in order.
  final readMarksCalls = <String>[];

  Completer<void>? _readMarksHold;

  /// Leaves the next [readMarks] read in flight until [releaseReadMarks].
  void holdReadMarks() => _readMarksHold = Completer<void>();
  void releaseReadMarks() {
    _readMarksHold?.complete();
    _readMarksHold = null;
  }

  @override
  Future<Result<List<ReadMark>>> readMarks(String conversationId) async {
    await _tick('readMarks:$conversationId');
    readMarksCalls.add(conversationId);
    final held = _readMarksHold;
    if (held != null) await held.future;
    if (readMarksResult case final forced?) return forced;
    return Ok(List.of(readMarksData[conversationId] ?? const []));
  }

  /// When set, readUpdates() reports a subscription that could not be made.
  Result<Stream<ReadMark>>? readUpdatesResult;

  /// Live read subscriptions per conversation. Like the real one, each is
  /// joined before readUpdates() resolves and keeps what arrives until it
  /// is listened to; nothing sent before the join reaches it.
  final _readSinks = <String, List<StreamController<ReadMark>>>{};
  int readSubscriptions = 0;
  int canceledReadSubscriptions = 0;
  Completer<void>? _subscribeReads;

  /// The server has not confirmed the read-marks subscription yet.
  void holdReadSubscription() => _subscribeReads = Completer<void>();
  void confirmReadSubscription() {
    _subscribeReads?.complete();
    _subscribeReads = null;
  }

  /// Delivers [mark] as Realtime would: to every subscription on
  /// [conversationId] joined by now. Without one it is gone.
  void deliverRead(String conversationId, ReadMark mark) {
    for (final sink in [...?_readSinks[conversationId]]) {
      sink.add(mark);
    }
  }

  @override
  Future<Result<Stream<ReadMark>>> readUpdates(String conversationId) async {
    await _tick('readUpdates:$conversationId');
    final held = _subscribeReads;
    if (held != null) await held.future;
    if (readUpdatesResult case final failed?) return failed;
    readSubscriptions++;
    late final StreamController<ReadMark> sink;
    sink = StreamController<ReadMark>(
      onCancel: () {
        canceledReadSubscriptions++;
        _readSinks[conversationId]?.remove(sink);
      },
    );
    (_readSinks[conversationId] ??= []).add(sink);
    return Ok(sink.stream);
  }
}

/// The refusals the storage bucket and the `messages` check constraint make.
///
/// Kept in one place so both fakes refuse exactly what the database refuses;
/// a fake that accepts everything is how an unvalidated upload ships green.
const attachmentMimeTypes = {
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
};
const attachmentSizeLimit = 10 * 1024 * 1024;

Err<Message>? rejectUpload(PickedImage image, String body) {
  if (image.bytes.isEmpty) {
    return const Err(ProviderFailure('the image is empty'));
  }
  if (image.bytes.length > attachmentSizeLimit) {
    return const Err(ProviderFailure('the image is larger than 10 MB'));
  }
  if (!attachmentMimeTypes.contains(image.contentType)) {
    return Err(ProviderFailure('${image.contentType} is not an image type'));
  }
  if (body.trim().length > maxMessageLength) {
    return const Err(ProviderFailure('the caption is too long'));
  }
  return null;
}

/// A 1x1 PNG: real bytes a real decoder accepts, which a made-up list is not.
final pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

PickedImage pickedPng({String contentType = 'image/png'}) =>
    PickedImage(bytes: pngBytes, contentType: contentType, extension: 'png');

/// A picker written from the [AttachmentSource] contract.
///
/// Every outcome a real picker has, including the two that are easy to forget:
/// the member backs out (null, and NOT a failure), and the platform throws.
/// Picking is never instant, so every outcome is delayed by [latency] —
/// code that assumes the sheet returns synchronously fails here.
class PickerFake implements AttachmentSource {
  PickerFake.returns(PickedImage image, {this.latency = Duration.zero})
    : _image = image,
      _error = null;

  /// The member opened the sheet and backed out.
  PickerFake.cancels({this.latency = Duration.zero})
    : _image = null,
      _error = null;

  /// The platform channel failed — no permission, no camera, no gallery.
  PickerFake.throwsError(Object error, {this.latency = Duration.zero})
    : _image = null,
      _error = error;

  final PickedImage? _image;
  final Object? _error;
  final Duration latency;

  /// How many times the member opened the picker.
  int calls = 0;

  @override
  Future<PickedImage?> pickImage() async {
    calls++;
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (_error case final error?) throw error;
    return _image;
  }
}

/// A gallery written from the [Gallery] contract in
/// lib/features/chat/domain/gallery.dart.
///
/// Nothing here is instant: every call takes at least [latency], so a sheet
/// that assumes recent() or load() answers synchronously fails here. Limited
/// access only ever returns what [allowed] actually holds -- exactly like
/// the platform, which never reveals a photo nobody agreed to share -- and
/// [selectMore] only adds to it once actually called, so a caller that
/// forgets to re-read after selectMore() cannot fake the extra photos into
/// view.
class GalleryFake implements Gallery {
  GalleryFake({
    this.access = GalleryAccess.full,
    List<GalleryPhoto> photos = const [],
    Iterable<String> allowed = const [],
    this.latency = Duration.zero,
  }) : photos = [...photos],
       allowed = {...allowed};

  /// What the next requestAccess() answers. Change it (e.g. denied -> full)
  /// to simulate the member granting access from "Allow access".
  GalleryAccess access;

  /// The library, newest first, before any access filtering.
  List<GalleryPhoto> photos;

  /// With limited access, which of [photos] the member has actually
  /// allowed so far. Ignored for full and denied access.
  Set<String> allowed;

  final Duration latency;

  /// How many times requestAccess() was called.
  int accessRequests = 0;

  /// How many times recent() was called.
  int recentCalls = 0;

  /// How many times selectMore() was called.
  int selectMoreCalls = 0;

  /// Every photo id [load] was asked for, in call order -- including a
  /// second tap that a correct sheet must never have made.
  final loadedIds = <String>[];

  /// Every photo id [thumbnail] was asked for.
  final thumbnailIds = <String>[];

  /// Per-photo thumbnail bytes. An id with no entry, or mapped to null,
  /// cannot be read -- the quiet tile the contract requires.
  final Map<String, Uint8List?> thumbnails = {};

  /// Per-photo load() outcome. An id with no entry loads a working image
  /// made from [pngBytes]; mapped to null means "cannot be opened".
  final Map<String, PickedImage?> loadResults = {};

  /// What the next selectMore() adds to [allowed].
  Set<String> selectMoreAdds = {};

  Completer<void>? _loadGate;

  /// The next [load] call stays in flight until [releaseLoad] -- long
  /// enough for a test to tap the same (or another) tile again and prove a
  /// second call never happens.
  void holdLoad() => _loadGate = Completer<void>();
  void releaseLoad() {
    _loadGate?.complete();
    _loadGate = null;
  }

  Future<void> _tick() async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
  }

  @override
  Future<GalleryAccess> requestAccess() async {
    accessRequests++;
    await _tick();
    return access;
  }

  @override
  Future<List<GalleryPhoto>> recent({int count = 60}) async {
    recentCalls++;
    await _tick();
    final visible = access == GalleryAccess.limited
        ? photos.where((p) => allowed.contains(p.id))
        : photos;
    return visible.take(count).toList();
  }

  @override
  Future<Uint8List?> thumbnail(GalleryPhoto photo, {int size = 240}) async {
    thumbnailIds.add(photo.id);
    await _tick();
    return thumbnails[photo.id];
  }

  @override
  Future<PickedImage?> load(GalleryPhoto photo) async {
    loadedIds.add(photo.id);
    await _tick();
    final gate = _loadGate;
    if (gate != null) await gate.future;
    if (loadResults.containsKey(photo.id)) return loadResults[photo.id];
    return PickedImage(
      bytes: pngBytes,
      contentType: 'image/png',
      extension: 'png',
    );
  }

  @override
  Future<void> selectMore() async {
    selectMoreCalls++;
    await _tick();
    allowed.addAll(selectMoreAdds);
  }
}

/// An [AttachmentCache] kept in memory, for tests that must give
/// [attachmentCacheProvider] something real to read, write and clear.
///
/// Signing out reads this before the session ends: a test asserting that
/// order needs to see whether the session was still active when [clear] ran,
/// the same way [PushRegistryFake.onForget] lets a test see the session at
/// the moment the device was forgotten.
class AttachmentCacheFake implements AttachmentCache {
  final _store = <String, Uint8List>{};

  /// How many times [clear] was called.
  int clears = 0;

  /// Runs synchronously as clear() is entered, before it finishes -- lets a
  /// test check what has (or has not) happened yet.
  void Function()? onClear;

  @override
  Future<Uint8List?> read(String path) async => _store[path];

  @override
  Future<void> write(String path, Uint8List bytes) async {
    _store[path] = bytes;
  }

  /// Every path [remove] was asked to forget, in order.
  final removed = <String>[];

  @override
  Future<void> remove(String path) async {
    removed.add(path);
    _store.remove(path);
  }

  @override
  Future<void> clear() async {
    clears++;
    onClear?.call();
    _store.clear();
  }
}

/// The shape the `profiles.tag` check constraint accepts.
final dbTagPattern = RegExp(r'^[a-z][a-z0-9_]{2,19}$');

/// A profile repository written from the [ProfileRepository] contract.
///
/// It answers like the database, not like the form: it refuses a tag the
/// check constraint refuses, a tag another account holds (the unique index,
/// 23505), and a display name outside 1..80. Every call is asynchronous, a
/// load, a save, or any single availability check can be held in flight and
/// released out of order, and another member can claim a tag between a check
/// and a save — the race the unique index exists for.
class ProfileFake implements ProfileRepository {
  ProfileFake({
    OwnProfile? profile,
    Iterable<String> takenByOthers = const [],
    this.latency = Duration.zero,
  }) : profile =
           profile ??
           const OwnProfile(
             userId: 'u1',
             displayName: 'Maya',
             tag: 'maya',
             onboardingDone: true,
           ),
       takenByOthers = {...takenByOthers};

  /// The row as the database holds it now.
  OwnProfile profile;

  /// Tags other accounts hold — including accounts RLS hides from the caller.
  final Set<String> takenByOthers;
  final Duration latency;

  /// Force an outcome; left null the fake answers from its own state.
  Result<OwnProfile>? loadResult;
  Result<OwnProfile>? saveResult;
  Result<bool>? availabilityResult;

  /// Call names in order: `load`, `save`, `check:<tag>`.
  final calls = <String>[];
  final saves =
      <
        ({
          String? displayName,
          String? tag,
          bool? onboardingDone,
          bool? sharePresence,
          bool? shareTyping,
          bool? shareLastSeen,
          bool? shareReadStatus,
        })
      >[];
  List<String> get checks => [
    for (final c in calls)
      if (c.startsWith('check:')) c.substring(6),
  ];

  /// Another member claims [tag] — e.g. between this member's check and save.
  void claimByOther(String tag) => takenByOthers.add(tag);

  Completer<void>? _load;
  Completer<void>? _save;
  final _held = <String, Completer<void>>{};
  final _holdTags = <String>{};

  void holdLoad() => _load = Completer<void>();
  void releaseLoad() {
    _load?.complete();
    _load = null;
  }

  void holdSave() => _save = Completer<void>();
  void releaseSave() {
    _save?.complete();
    _save = null;
  }

  /// The next availability check for [tag] stays in flight until
  /// [releaseCheck]. Its answer is the database as it stood when it was asked.
  void holdCheck(String tag) => _holdTags.add(tag);
  void releaseCheck(String tag) => _held.remove(tag)?.complete();

  Future<void> _tick(String call) async {
    calls.add(call);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
  }

  @override
  Future<Result<OwnProfile>> load() async {
    await _tick('load');
    final held = _load;
    if (held != null) await held.future;
    return loadResult ?? Ok(profile);
  }

  @override
  Future<Result<OwnProfile>> save({
    String? displayName,
    String? tag,
    bool? onboardingDone,
    bool? sharePresence,
    bool? shareTyping,
    bool? shareLastSeen,
    bool? shareReadStatus,
  }) async {
    await _tick('save');
    saves.add((
      displayName: displayName,
      tag: tag,
      onboardingDone: onboardingDone,
      sharePresence: sharePresence,
      shareTyping: shareTyping,
      shareLastSeen: shareLastSeen,
      shareReadStatus: shareReadStatus,
    ));
    final held = _save;
    if (held != null) await held.future;
    if (saveResult case final forced?) return forced;
    if (displayName != null &&
        (displayName.trim().isEmpty || displayName.length > 80)) {
      return const Err(ProviderFailure('That name or tag is not allowed.'));
    }
    if (tag != null && !dbTagPattern.hasMatch(tag)) {
      return const Err(ProviderFailure('That name or tag is not allowed.'));
    }
    if (tag != null && takenByOthers.contains(tag)) {
      return const Err(ProviderFailure('That tag was just taken by someone.'));
    }
    // One statement: every field lands, or none does.
    profile = OwnProfile(
      userId: profile.userId,
      displayName: displayName ?? profile.displayName,
      tag: tag ?? profile.tag,
      onboardingDone: onboardingDone ?? profile.onboardingDone,
      sharePresence: sharePresence ?? profile.sharePresence,
      shareTyping: shareTyping ?? profile.shareTyping,
      shareLastSeen: shareLastSeen ?? profile.shareLastSeen,
      shareReadStatus: shareReadStatus ?? profile.shareReadStatus,
    );
    return Ok(profile);
  }

  @override
  Future<Result<bool>> isTagAvailable(String tag) async {
    final answer =
        dbTagPattern.hasMatch(tag) &&
        (tag == profile.tag || !takenByOthers.contains(tag));
    await _tick('check:$tag');
    if (_holdTags.remove(tag)) {
      final gate = _held[tag] = Completer<void>();
      await gate.future;
    }
    return availabilityResult ?? Ok(answer);
  }
}

/// One `online()` join, as the server sees it.
class OnlineJoin {
  OnlineJoin(this.share);

  /// Whether this join announces the caller.
  final bool share;

  /// Set once the server confirmed the channel.
  bool confirmed = false;

  /// Set once the caller let go of the channel (cancelled its stream).
  bool left = false;

  StreamController<Set<String>>? _events;
  Completer<void>? _gate;
}

/// A presence repository written from the [PresenceRepository] contract.
///
/// Joining takes time and can be held open: the server has not confirmed yet.
/// A confirmed online channel announces the caller (when it shares) until the
/// caller cancels its stream — a join nobody listens to and cancels stays
/// announcing, exactly as a joined Realtime channel stays joined. Events reach
/// a live listener only; the first presence state arrives just after the
/// listener attaches, not synchronously with the join.
class PresenceFake implements PresenceRepository {
  PresenceFake({this.selfId = 'u1', this.latency = Duration.zero, this.owner});

  /// The caller's own profile row, as the server reads it. When set, last
  /// seen is mutual the way `last_seen_of` is: while the caller does not
  /// share, every answer is null and a touch records nothing. Left null the
  /// caller is taken to share.
  final ProfileFake? owner;

  bool get _callerShares => owner?.profile.shareLastSeen ?? true;

  /// Last seen as the server stores it. Only members who share are here; a
  /// member turning sharing off is removed, as the delete trigger does.
  final lastSeen = <String, DateTime>{};

  /// Force the outcome of the next [lastSeenOf] / [touchLastSeen] calls.
  Result<DateTime?>? lastSeenResult;
  Result<void>? touchResult;
  Completer<void>? _lastSeenHold;

  /// [lastSeenOf] calls stay in flight until [releaseLastSeen]. The answer
  /// is the server's state when the query ran, not when it is released.
  void holdLastSeen() => _lastSeenHold ??= Completer<void>();
  void releaseLastSeen() {
    _lastSeenHold?.complete();
    _lastSeenHold = null;
  }

  /// How many times the caller reported itself seen.
  int get touches => calls.where((c) => c == 'touch').length;

  @override
  Future<Result<void>> touchLastSeen() async {
    await _tick('touch');
    if (touchResult case final forced?) return forced;
    if (_callerShares) lastSeen[selfId] = DateTime.now();
    return const Ok(null);
  }

  @override
  Future<Result<DateTime?>> lastSeenOf(String userId) async {
    final answer = _callerShares ? lastSeen[userId] : null;
    await _tick('lastSeen:$userId');
    final hold = _lastSeenHold;
    if (hold != null) await hold.future;
    if (lastSeenResult case final forced?) return forced;
    return Ok(answer);
  }

  /// The caller; present in the online set only while a sharing join is live.
  final String selfId;
  final Duration latency;

  /// When set, the join is refused with this failure.
  Failure? onlineRefusal;
  Failure? typingRefusal;

  /// Call names in order: `online:share`, `online:hidden`, `typing:<id>`.
  final calls = <String>[];
  final joins = <OnlineJoin>[];
  final typingChannels = <FakeTypingChannel>[];

  Set<String> _others = {};
  bool _holdingOnline = false;
  Completer<void>? _typingHold;

  /// Joins currently holding the caller visible to everyone else.
  List<OnlineJoin> get announcing => [
    for (final j in joins)
      if (j.share && j.confirmed && !j.left) j,
  ];

  /// Channels the caller still holds open.
  List<OnlineJoin> get live => [
    for (final j in joins)
      if (j.confirmed && !j.left) j,
  ];

  /// The open typing channel for [conversationId], if any.
  FakeTypingChannel? typingIn(String conversationId) => typingChannels
      .where((c) => c.conversationId == conversationId && !c.closed)
      .lastOrNull;

  /// Joins started after this stay pending until released — all at once
  /// ([releaseOnline]) or one by one, in any order ([releaseJoin]).
  void holdOnline() => _holdingOnline = true;
  void releaseOnline() {
    _holdingOnline = false;
    for (final j in joins) {
      releaseJoin(j);
    }
  }

  void releaseJoin(OnlineJoin join) {
    final gate = join._gate;
    join._gate = null;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  void holdTyping() => _typingHold ??= Completer<void>();
  void releaseTyping() {
    _typingHold?.complete();
    _typingHold = null;
  }

  /// Other members come and go; every live channel hears about it.
  void setOthersOnline(Iterable<String> ids) {
    _others = {...ids};
    for (final j in live) {
      j._events?.add(_stateFor(j));
    }
  }

  Set<String> _stateFor(OnlineJoin j) => {..._others, if (j.share) selfId};

  Future<void> _tick(String call) async {
    calls.add(call);
    await Future<void>.delayed(latency);
  }

  @override
  Future<Result<Stream<Set<String>>>> online({required bool share}) async {
    final join = OnlineJoin(share);
    joins.add(join);
    if (_holdingOnline) join._gate = Completer<void>();
    final gate = join._gate;
    await _tick(share ? 'online:share' : 'online:hidden');
    if (gate != null) await gate.future;
    if (onlineRefusal case final refused?) return Err(refused);
    join.confirmed = true;
    late final StreamController<Set<String>> events;
    events = StreamController<Set<String>>(
      onListen: () => scheduleMicrotask(() {
        if (!join.left) events.add(_stateFor(join));
      }),
      onCancel: () => join.left = true,
    );
    join._events = events;
    return Ok(events.stream);
  }

  @override
  Future<Result<TypingChannel>> typing(String conversationId) async {
    await _tick('typing:$conversationId');
    final hold = _typingHold;
    if (hold != null) await hold.future;
    if (typingRefusal case final refused?) return Err(refused);
    final channel = FakeTypingChannel(conversationId);
    typingChannels.add(channel);
    return Ok(channel);
  }
}

/// A typing channel for one conversation: others' signals arrive only while
/// someone listens, the caller's own signals are counted and never echoed.
class FakeTypingChannel implements TypingChannel {
  FakeTypingChannel(this.conversationId);

  final String conversationId;
  final _typists = StreamController<String>.broadcast();
  bool closed = false;

  /// Signals the caller sent while the channel was open.
  int signals = 0;

  /// Signals attempted after close — a leak, never counted as sent.
  int signalsAfterClose = 0;

  /// Another member typed in this conversation.
  void type(String userId) {
    if (!closed) _typists.add(userId);
  }

  @override
  Stream<String> get typists => _typists.stream;

  @override
  Future<void> signal() async {
    if (closed) {
      signalsAfterClose++;
      return;
    }
    signals++;
  }

  @override
  Future<void> close() async {
    closed = true;
    await _typists.close();
  }
}

/// A push source written from the [PushSource] contract.
///
/// Nothing here is instant: a platform channel round trip always takes at
/// least [latency], and permission or the token can be held open past that
/// while a test does something else first. A refused permission is a plain
/// false, never a failure -- the contract says asking again must not nag.
class PushSourceFake implements PushSource {
  PushSourceFake({
    this.permissionGranted = true,
    String? token = 'device-token-1',
    this.launchConversationId,
    this.latency = Duration.zero,
  }) : currentToken = token;

  /// What the next requestPermission() answers.
  bool permissionGranted;

  /// The device's current token; null when the platform has none yet. Set
  /// directly to change what the next token() read answers.
  String? currentToken;

  /// The conversation id a cold start answers with, once.
  String? launchConversationId;

  final Duration latency;

  int permissionRequests = 0;
  int tokenReads = 0;
  int launchConversationReads = 0;

  Completer<void>? _permissionGate;
  Completer<void>? _tokenGate;

  /// The next requestPermission() call stays in flight until
  /// [releasePermission].
  void holdPermission() => _permissionGate = Completer<void>();
  void releasePermission() {
    _permissionGate?.complete();
    _permissionGate = null;
  }

  /// The next token() call stays in flight until [releaseToken].
  void holdToken() => _tokenGate = Completer<void>();
  void releaseToken() {
    _tokenGate?.complete();
    _tokenGate = null;
  }

  final _refreshes = StreamController<String>.broadcast();
  final _opened = StreamController<String>.broadcast();

  /// The platform rotates the token -- the device's own record changes too,
  /// so a later [token] read agrees with the last refresh.
  void refreshToken(String next) {
    currentToken = next;
    _refreshes.add(next);
  }

  /// The member taps a notification while the app runs in the background.
  void openConversation(String id) => _opened.add(id);

  /// Every conversation id [clearConversation] was called for, in order.
  final cleared = <String>[];

  /// How many times [clearAll] was called.
  int clearAllCalls = 0;

  @override
  Future<void> clearConversation(String conversationId) async {
    cleared.add(conversationId);
  }

  @override
  Future<void> clearAll() async {
    clearAllCalls++;
  }

  /// Every member [forUser] was told about, in order (null = nobody).
  final users = <String?>[];

  /// Runs synchronously as forUser() is entered -- lets a test check what
  /// had (or had not) happened yet, e.g. whether the new member's token was
  /// already registered.
  void Function(String? userId)? onForUser;

  @override
  Future<void> forUser(String? userId) async {
    users.add(userId);
    onForUser?.call(userId);
    await Future<void>.delayed(latency); // a platform round trip
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    await Future<void>.delayed(latency);
    final gate = _permissionGate;
    if (gate != null) await gate.future;
    return permissionGranted;
  }

  @override
  Future<String?> token() async {
    tokenReads++;
    await Future<void>.delayed(latency);
    final gate = _tokenGate;
    if (gate != null) await gate.future;
    return currentToken;
  }

  @override
  Stream<String> get tokenRefreshes => _refreshes.stream;

  @override
  Future<String?> launchConversation() async {
    launchConversationReads++;
    await Future<void>.delayed(latency);
    return launchConversationId;
  }

  @override
  Stream<String> get openedConversations => _opened.stream;
}

/// A push registry written from the [PushRegistry] contract.
///
/// Answers like the server: refuses when told to, and otherwise records what
/// was claimed and what was forgotten so a test can check what happened, and
/// in what order relative to everything else (e.g. signing out).
class PushRegistryFake implements PushRegistry {
  PushRegistryFake({this.latency = Duration.zero});

  final Duration latency;

  /// Forces the outcome of the next register()/forget() call; left null both
  /// succeed.
  Result<void>? registerResult;
  Result<void>? forgetResult;

  /// Every token registered, in order -- the last one is what the server
  /// currently has on file for this device.
  final registered = <String>[];

  /// Every token forgotten, in order.
  final forgotten = <String>[];

  /// Every call, as `register:<token>` / `forget:<token>`, in the order made.
  final calls = <String>[];

  /// Runs synchronously as forget() is entered, before its result is
  /// decided -- lets a test check what has (or has not) happened yet, e.g.
  /// that the session has not signed out.
  void Function(String token)? onForget;

  @override
  Future<Result<void>> register(String token) async {
    calls.add('register:$token');
    await Future<void>.delayed(latency);
    if (registerResult case final forced?) return forced;
    registered.add(token);
    return const Ok(null);
  }

  @override
  Future<Result<void>> forget(String token) async {
    calls.add('forget:$token');
    onForget?.call(token);
    await Future<void>.delayed(latency);
    if (forgetResult case final forced?) return forced;
    forgotten.add(token);
    return const Ok(null);
  }
}

/// A link opener written from the [LinkOpener] contract.
///
/// Opening is never instant: the OS resolves an app first, so the answer is
/// delayed by [latency]. It can decline (no browser, a blocked scheme), and
/// that decline is a plain false — the contract says an opener never throws.
class LinkOpenerFake implements LinkOpener {
  LinkOpenerFake({this.opens = true, this.latency = Duration.zero});

  /// What [open] answers.
  bool opens;
  final Duration latency;

  /// Every link asked for, in order.
  final opened = <Uri>[];

  @override
  Future<bool> open(Uri link) async {
    opened.add(link);
    await Future<void>.delayed(latency);
    return opens;
  }
}

/// Lets real image decoding finish: it runs in the engine, outside the fake
/// clock, exactly as on a device where a photo has a size only once decoded.
Future<void> settleImages(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

/// A 320x240 PNG: a photo with a size, so a thumbnail that sizes itself to
/// its image has something to tap once it has decoded.
final photoPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAUAAAADwCAIAAAD+Tyo8AAACD0lEQVR42u3TQQkAAAgEwYtmFKMZ1Q7+hIFJsLDpGuCpSAAGBgwMGBgMDBgYMDBgYDAwYGDAwGBgwMCAgQEDg4EBAwMGBgwMBgYMDBgYDAwYGDAwYGAwMGBgwMCAgcHAgIEBA4OBAQMDBgYMDAYGDAwYGAysAhgYMDBgYDAwYGDAwICBwcCAgQEDg4EBAwMGBgwMBgYMDBgYMDAYGDAwYGAwMGBgwMCAgcHAgIEBAwMGBgMDBgYMDAYGDAwYGDAwGBgwMGBgMDBgYMDAgIHBwICBAQMDBgYDAwYGDAwGBgwMGBgwMBgYMDBgYMDAYGDAwICBwcCAgQEDAwYGAwMGBgwMGBgMDBgYMDAYGDAwYGDAwGBgwMCAgcHAgIEBAwMGBgMDBgYMDBgYDAwYGDAwGBgwMGBgwMBgYMDAgIEBA4OBAQMDBgYDAwYGDAwYGAwMGBgwMBhYBTAwYGDAwGBgwMCAgQEDg4EBAwMGBgMDBgYMDBgYDAwYGDAwYGAwMGBgwMBgYMDAgIEBA4OBAQMDBgYMDAYGDAwYGAwMGBgwMGBgMDBgYMDAYGDAwICBAQODgQEDAwYGDAwGBgwMGBgMDBgYMDBgYDAwYGDAwICBwcCAgQEDg4EBAwMGBgwMBgYMDBgYMDAYGDAwYGAwMGBgwMCAgcHAgIEBA4OBAQMDBgYMDAYGDAwYGDAwGBgwMHC3w4QV+mvl+L0AAAAASUVORK5CYII=',
);

/// Serves a real PNG to any request, so a widget that renders a signed URL
/// decodes actual bytes instead of the 400 the test harness returns by
/// default. A URL whose path contains one of [missing] answers 404 instead:
/// a signed URL that was issued but whose object is gone, the broken image a
/// device really sees.
class ImageServer extends HttpOverrides {
  ImageServer({this.missing = const {}});

  final Set<String> missing;

  @override
  HttpClient createHttpClient(SecurityContext? context) => _ImageClient(this);
}

class _ImageClient implements HttpClient {
  _ImageClient(this.server);
  final ImageServer server;

  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Duration idleTimeout = const Duration(seconds: 15);
  @override
  int? maxConnectionsPerHost;
  @override
  String? userAgent;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _ImageRequest(url, found: !server.missing.any(url.path.contains));
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('get', url);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ImageRequest implements HttpClientRequest {
  _ImageRequest(this.uri, {required this.found});
  @override
  final Uri uri;
  final bool found;
  @override
  final HttpHeaders headers = _NoHeaders();

  @override
  Future<HttpClientResponse> close() async => _ImageResponse(found);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoHeaders implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  _ImageResponse(this.found);
  final bool found;

  List<int> get _body => found ? photoPng : utf8.encode('not found');

  @override
  int get statusCode => found ? HttpStatus.ok : HttpStatus.notFound;
  @override
  int get contentLength => _body.length;
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  HttpHeaders get headers => _NoHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_body).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// A notification settings repository written from the
/// [NotificationSettingsRepository] contract: defaults when nothing is
/// saved, a mute replaces any existing one for the same kind and target, and
/// every call can be forced to a failure or held in flight, the way a real
/// request can arrive slowly or not at all.
class NotificationSettingsFake implements NotificationSettingsRepository {
  NotificationSettingsFake({
    this.settings = const NotificationSettings(),
    Iterable<Mute> mutes = const [],
    this.latency = Duration.zero,
  }) : savedMutes = [...mutes];

  /// The row as the database holds it now.
  NotificationSettings settings;

  /// Every saved mute, expired ones included, as the database holds them.
  List<Mute> savedMutes;

  final Duration latency;

  /// Force an outcome; left null the fake answers from its own state.
  Result<NotificationSettings>? loadResult;
  Result<void>? saveResult;
  Result<List<Mute>>? mutesResult;
  Result<void>? muteResult;
  Result<void>? unmuteResult;

  /// Call names in order: `load`, `save`, `mutes`, `mute`, `unmute`.
  final calls = <String>[];
  final saves = <NotificationSettings>[];
  final muteCalls = <(MuteKind kind, String target, DateTime? until)>[];
  final unmuteCalls = <(MuteKind kind, String target)>[];

  Completer<void>? _loadHold;
  Completer<void>? _mutesHold;

  /// The next [load] stays in flight until [releaseLoad].
  void holdLoad() => _loadHold = Completer<void>();
  void releaseLoad() {
    _loadHold?.complete();
    _loadHold = null;
  }

  /// The next [mutes] read stays in flight until [releaseMutes].
  void holdMutes() => _mutesHold = Completer<void>();
  void releaseMutes() {
    _mutesHold?.complete();
    _mutesHold = null;
  }

  Future<void> _tick(String call) async {
    calls.add(call);
    if (latency > Duration.zero) await Future<void>.delayed(latency);
  }

  @override
  Future<Result<NotificationSettings>> load() async {
    await _tick('load');
    if (_loadHold case final hold?) await hold.future;
    return loadResult ?? Ok(settings);
  }

  @override
  Future<Result<void>> save(NotificationSettings next) async {
    await _tick('save');
    saves.add(next);
    if (saveResult case final forced?) return forced;
    settings = next;
    return const Ok(null);
  }

  @override
  Future<Result<List<Mute>>> mutes() async {
    await _tick('mutes');
    if (_mutesHold case final hold?) await hold.future;
    return mutesResult ?? Ok([...savedMutes]);
  }

  @override
  Future<Result<void>> mute(
    MuteKind kind,
    String target,
    DateTime? until,
  ) async {
    await _tick('mute');
    muteCalls.add((kind, target, until));
    if (muteResult case final forced?) return forced;
    savedMutes = [
      for (final m in savedMutes)
        if (m.kind != kind || m.target != target) m,
      Mute(kind: kind, target: target, until: until),
    ];
    return const Ok(null);
  }

  @override
  Future<Result<void>> unmute(MuteKind kind, String target) async {
    await _tick('unmute');
    unmuteCalls.add((kind, target));
    if (unmuteResult case final forced?) return forced;
    savedMutes = [
      for (final m in savedMutes)
        if (m.kind != kind || m.target != target) m,
    ];
    return const Ok(null);
  }
}
