// Fakes for the design-foundation tests, written from the domain interfaces
// only. They mount the whole app through SisApp, the way main.dart does, with
// a fake at each repository boundary and nothing else overridden.
//
// Deliberately not instant where the real dependency is not: presence emits
// its first set only after the listener attaches (a Realtime sync arrives
// after the join), and typing arrives whenever the test says so.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sis/app/sis_app.dart';
import 'package:sis/core/failure.dart';
import 'package:sis/core/runtime_config.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/application/chat_controllers.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/presence/application/presence_controllers.dart';
import 'package:sis/features/presence/domain/presence_repository.dart';
import 'package:sis/features/profile/application/profile_controller.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/domain/profile_repository.dart';
import 'package:sis/features/update/application/update_controller.dart';
import 'package:sis/features/update/domain/update_repository.dart';

const me = Member(userId: 'u1', displayName: 'Maya Kaya', tag: 'maya');

class DesignAuth implements AuthRepository {
  DesignAuth({this.session = false, this.signInResult = const Ok(null)});

  bool session;
  Result<void> signInResult;
  int signInCalls = 0;
  final _changes = StreamController<bool>.broadcast();

  @override
  bool get hasSession => session;
  @override
  Stream<bool> get signedInChanges => _changes.stream;

  @override
  Future<Result<void>> signInWithGoogle() async {
    signInCalls++;
    await Future<void>.delayed(Duration.zero);
    if (signInResult is Ok) {
      session = true;
      _changes.add(true);
    }
    return signInResult;
  }

  @override
  Future<Result<bool>> activateSession() async => const Ok(true);
  @override
  Future<Result<Member>> currentMember() async => const Ok(me);
  @override
  Future<void> signOut() async {
    session = false;
    _changes.add(false);
  }
}

class DesignUpdate implements UpdateRepository {
  @override
  Future<int> installedBuild() async => 10;
  @override
  Future<Result<int>> minSupportedBuild() async => const Ok(1);
  @override
  Future<Result<int?>> availablePlayBuild() async => const Ok(null);
  @override
  Future<void> startFlexibleUpdate() async {}
  @override
  Future<void> completeFlexibleUpdate() async {}
  @override
  Future<void> startImmediateUpdate() async {}
  @override
  Future<void> openStoreListing() async {}
}

class DesignChat implements ChatRepository {
  DesignChat({
    this.list = const [],
    this.people = const [],
    Map<String, List<Message>>? history,
  }) : history = history ?? {};

  List<Conversation> list;
  List<Member> people;
  final Map<String, List<Message>> history;
  final _incoming = <String, StreamController<Message>>{};
  final _all = StreamController<Message>.broadcast();

  void deliver(Message m) {
    _all.add(m);
    _incoming[m.conversationId]?.add(m);
  }

  @override
  Future<Result<List<Member>>> members() async => Ok(people);
  @override
  Future<Result<List<Conversation>>> conversations() async => Ok(list);
  @override
  Future<Result<void>> markRead(String conversationId) async {
    list = [
      for (final c in list)
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
    ];
    return const Ok(null);
  }

  @override
  Future<Result<List<Message>>> messages(String conversationId) async =>
      Ok(history[conversationId] ?? const []);

  @override
  Future<Result<Message>> send({
    required String conversationId,
    required String body,
  }) async => Ok(
    Message(
      id: 'sent-${DateTime.now().microsecondsSinceEpoch}',
      conversationId: conversationId,
      senderId: me.userId,
      body: body,
      createdAt: DateTime.now().toUtc(),
    ),
  );

  @override
  Future<Result<Stream<Message>>> incoming(String conversationId) async => Ok(
    (_incoming[conversationId] ??= StreamController<Message>.broadcast())
        .stream,
  );
  @override
  Future<Result<Stream<Message>>> incomingAll() async => Ok(_all.stream);
  @override
  Future<Result<String>> startDirectConversation(String otherUserId) async =>
      Ok('c-$otherUserId');
  @override
  Future<Result<String>> startGroupConversation({
    required String title,
    required List<String> memberIds,
  }) async => const Ok('g-new');
  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
  }) async => const Err(NetworkFailure('not in this test'));
  @override
  Future<Result<Uri>> attachmentUrl(String attachmentPath) async =>
      const Err(NetworkFailure('not in this test'));
}

class DesignTyping implements TypingChannel {
  final _typists = StreamController<String>.broadcast();
  void type(String userId) => _typists.add(userId);
  @override
  Stream<String> get typists => _typists.stream;
  @override
  Future<void> signal() async {}
  @override
  Future<void> close() async {}
}

class DesignPresence implements PresenceRepository {
  DesignPresence({Set<String> online = const {}}) : _online = {...online};

  Set<String> _online;
  final _streams = <StreamController<Set<String>>>[];
  final channels = <String, DesignTyping>{};

  void setOnline(Set<String> ids) {
    _online = ids;
    for (final s in _streams) {
      s.add(ids);
    }
  }

  @override
  Future<Result<Stream<Set<String>>>> online({required bool share}) async {
    late final StreamController<Set<String>> c;
    c = StreamController<Set<String>>(
      // The first sync comes after the join, never synchronously with it.
      onListen: () => scheduleMicrotask(() => c.add(_online)),
      onCancel: () => _streams.remove(c),
    );
    _streams.add(c);
    return Ok(c.stream);
  }

  @override
  Future<Result<TypingChannel>> typing(String conversationId) async =>
      Ok(channels.putIfAbsent(conversationId, DesignTyping.new));

  @override
  Future<Result<void>> touchLastSeen() async => const Ok(null);

  @override
  Future<Result<DateTime?>> lastSeenOf(String userId) async => const Ok(null);
}

class DesignProfile implements ProfileRepository {
  OwnProfile profile = const OwnProfile(
    userId: 'u1',
    displayName: 'Maya Kaya',
    tag: 'maya',
    onboardingDone: true,
  );

  @override
  Future<Result<OwnProfile>> load() async => Ok(profile);
  @override
  Future<Result<OwnProfile>> save({
    String? displayName,
    String? tag,
    bool? onboardingDone,
    bool? sharePresence,
    bool? shareTyping,
    bool? shareLastSeen,
  }) async => Ok(
    profile = OwnProfile(
      userId: profile.userId,
      displayName: displayName ?? profile.displayName,
      tag: tag ?? profile.tag,
      onboardingDone: onboardingDone ?? profile.onboardingDone,
      sharePresence: sharePresence ?? profile.sharePresence,
      shareTyping: shareTyping ?? profile.shareTyping,
      shareLastSeen: shareLastSeen ?? profile.shareLastSeen,
    ),
  );
  @override
  Future<Result<bool>> isTagAvailable(String tag) async => const Ok(true);
}

/// The app as main.dart mounts it, with fakes at the repository boundary.
Widget designApp({
  required DesignAuth auth,
  DesignChat? chat,
  DesignPresence? presence,
  DesignProfile? profile,
}) => ProviderScope(
  overrides: [
    runtimeConfigProvider.overrideWithValue(
      const RuntimeConfig(
        supabaseUrl: 'https://x.supabase.co',
        supabasePublishableKey: 'k',
        googleWebClientId: 'c',
      ),
    ),
    authRepositoryProvider.overrideWithValue(auth),
    updateRepositoryProvider.overrideWithValue(DesignUpdate()),
    chatRepositoryProvider.overrideWithValue(chat ?? DesignChat()),
    presenceRepositoryProvider.overrideWithValue(presence ?? DesignPresence()),
    profileRepositoryProvider.overrideWithValue(profile ?? DesignProfile()),
  ],
  child: const SisApp(),
);
