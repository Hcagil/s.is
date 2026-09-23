// Hand-written fakes shared by controller and widget tests.
import 'dart:async';
import 'dart:convert';

import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/presence/domain/presence_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/domain/profile_repository.dart';
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

  @override
  Future<Result<List<Conversation>>> conversations() async {
    listReads++;
    if (listGate != null) await listGate!.future;
    return conversationsResult ?? Ok(list);
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
      <({String conversationId, PickedImage image, String body})>[];

  /// Every path [attachmentUrl] was asked to sign, in order.
  final urlRequests = <String>[];

  /// Keys this fake has actually stored. A path it never stored cannot be
  /// signed, exactly as the bucket refuses to sign an object the caller may
  /// not read. Seed it with [store] when a test invents history.
  final storedObjects = <String>{};
  void store(String path) => storedObjects.add(path);

  /// Force an outcome. Left null both calls answer like the real thing: the
  /// upload refuses what the bucket and the check constraint refuse, and a
  /// URL is issued only for a stored key.
  Result<Message>? sendImageResult;
  Result<Uri>? attachmentUrlResult;

  int _imageSeq = 0;

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
  }) async {
    sentImages.add((conversationId: conversationId, image: image, body: body));
    if (sendImageResult case final forced?) return forced;
    if (rejectUpload(image, body) case final refused?) return refused;
    final path = '$conversationId/${++_imageSeq}.${image.extension}';
    storedObjects.add(path);
    return Ok(
      Message(
        id: 'img-$_imageSeq',
        conversationId: conversationId,
        senderId: 'me',
        body: body.trim(),
        createdAt: DateTime.now(),
        attachmentPath: path,
      ),
    );
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
  /// One insert reaches the conversation's own subscription and every
  /// list-wide one ([incomingAll]) alike.
  void deliver(Message m) {
    _streams[m.conversationId]?.add(m);
    _all?.add(m);
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
    return membersResult;
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
      <({String conversationId, PickedImage image, String body})>[];

  /// Every path [attachmentUrl] was asked to sign, in order.
  final urlRequests = <String>[];

  /// Keys this fake has actually stored. A path it never stored cannot be
  /// signed, exactly as the bucket refuses to sign an object the caller may
  /// not read. Seed it with [store] when a test invents history.
  final storedObjects = <String>{};
  void store(String path) => storedObjects.add(path);

  /// Force an outcome. Left null both calls answer like the real thing: the
  /// upload refuses what the bucket and the check constraint refuse, and a
  /// URL is issued only for a stored key.
  Result<Message>? sendImageResult;
  Result<Uri>? attachmentUrlResult;

  int _imageSeq = 0;

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
  }) async {
    await _tick('sendImage:$conversationId');
    sentImages.add((conversationId: conversationId, image: image, body: body));
    if (sendImageResult case final forced?) return forced;
    if (rejectUpload(image, body) case final refused?) return refused;
    final path = '$conversationId/${++_imageSeq}.${image.extension}';
    storedObjects.add(path);
    return Ok(
      Message(
        id: 'img-$_imageSeq',
        conversationId: conversationId,
        senderId: 'me',
        body: body.trim(),
        createdAt: DateTime.now(),
        attachmentPath: path,
      ),
    );
  }

  @override
  Future<Result<Uri>> attachmentUrl(String attachmentPath) async {
    await _tick('attachmentUrl:$attachmentPath');
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
  }) async {
    await _tick('save');
    saves.add((
      displayName: displayName,
      tag: tag,
      onboardingDone: onboardingDone,
      sharePresence: sharePresence,
      shareTyping: shareTyping,
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
  PresenceFake({this.selfId = 'u1', this.latency = Duration.zero});

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
