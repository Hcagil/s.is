// Fakes for more than one account on one phone.
//
// On a device every repository sits over ONE Supabase client, and the client
// holds ONE session. So every call answers as whoever is signed in at the
// moment the call is made, and a Realtime channel stays joined as whoever
// joined it. A fake with a fixed "me" cannot tell a provider that re-asked
// from one that kept the previous account's answer; these fakes all read the
// signed-in account from one shared [Backend], the way the real ones read it
// from the one client.
import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/auth/domain/auth_repository.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/domain/attachment.dart';
import 'package:sis/features/chat/domain/chat_repository.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/chat/domain/links.dart';
import 'package:sis/features/chat/domain/message.dart';
import 'package:sis/features/presence/domain/presence_repository.dart';
import 'package:sis/features/profile/domain/own_profile.dart';
import 'package:sis/features/profile/domain/profile_repository.dart';

/// One conversation as the database stores it.
class Room {
  Room(this.id, this.members, {this.title});
  final String id;
  final Set<String> members;
  final String? title;
  final messages = <Message>[];
}

/// The server: accounts, conversations, and who holds the session now.
class Backend {
  Backend({required Map<String, OwnProfile> profiles, required this.emails})
    : profiles = {...profiles};

  /// Every allowlisted account's profile row, by user id.
  final Map<String, OwnProfile> profiles;
  final Map<String, String> emails;
  final rooms = <Room>[];

  /// Who the one client is signed in as right now; null when signed out.
  String? signedIn;

  /// Last seen as stored, for members who share it.
  final lastSeen = <String, DateTime>{};

  Room room(String id, Set<String> members, {String? title}) {
    final r = Room(id, members, title: title);
    rooms.add(r);
    return r;
  }

  Member memberOf(String userId, {bool withEmail = false}) {
    final p = profiles[userId]!;
    return Member(
      userId: userId,
      displayName: p.displayName,
      tag: p.tag,
      email: withEmail ? emails[userId] : null,
    );
  }

  /// A real call is never synchronous.
  Future<void> hop() => Future<void>.delayed(Duration.zero);
}

/// [AuthRepository] over the [Backend]'s one session.
///
/// Like the real repository: signing in replaces the session and then emits
/// `true`; signing out ends it and then emits `false`; [currentMember] reads
/// whoever holds the session when it is asked, and is refused without one.
class SwitchingAuth implements AuthRepository {
  SwitchingAuth(this.backend);
  final Backend backend;

  /// The Google account the member picks in the next sign-in sheet.
  String? chosen;
  int signOuts = 0;

  // The real stream is `.distinct()`: no repeated value reaches a listener.
  final _changes = StreamController<bool>.broadcast();
  bool? _last;
  void _emit(bool v) {
    if (v == _last) return;
    _last = v;
    _changes.add(v);
  }

  @override
  bool get hasSession => backend.signedIn != null;

  @override
  Stream<bool> get signedInChanges => _changes.stream;

  @override
  Future<Result<void>> signInWithGoogle() async {
    await backend.hop();
    final who = chosen;
    if (who == null) {
      return const Err(
        ProviderFailure('Google sign-in canceled', userCanceled: true),
      );
    }
    backend.signedIn = who;
    _emit(true);
    await backend.hop();
    return const Ok(null);
  }

  @override
  Future<Result<bool>> activateSession() async {
    final who = backend.signedIn;
    await backend.hop();
    if (who == null) return const Err(DeniedFailure());
    return Ok(backend.profiles.containsKey(who));
  }

  @override
  Future<Result<Member>> currentMember() async {
    final who = backend.signedIn;
    await backend.hop();
    if (who == null || !backend.profiles.containsKey(who)) {
      return const Err(DeniedFailure());
    }
    return Ok(backend.memberOf(who, withEmail: true));
  }

  @override
  Future<void> signOut() async {
    signOuts++;
    await backend.hop();
    backend.signedIn = null;
    _emit(false);
  }
}

/// [ChatRepository] answering as the session holder at call time, with
/// row-level security's manners: no session or no membership reads as
/// nothing, and a write is refused.
class SessionChat implements ChatRepository {
  SessionChat(this.backend);
  final Backend backend;

  /// Calls as `<call> as <userId|anon>`, in order.
  final calls = <String>[];

  Completer<void>? _listHold;

  /// The next [conversations] read stays in flight until [releaseList]. Its
  /// answer is the database as it stood, for whoever asked, when it ran.
  void holdList() => _listHold = Completer<void>();
  void releaseList() {
    _listHold?.complete();
    _listHold = null;
  }

  /// Live list-wide subscriptions and the account each was opened as.
  final allSubscriptions = <({String? as, StreamController<Message> sink})>[];
  final subscriptions =
      <({String? as, String id, StreamController<Message> sink})>[];

  List<String?> get liveAllAs => [
    for (final s in allSubscriptions)
      if (s.sink.hasListener) s.as,
  ];
  List<String> get liveIncoming => [
    for (final s in subscriptions)
      if (s.sink.hasListener) '${s.id} as ${s.as}',
  ];

  Future<String?> _as(String call) async {
    final who = backend.signedIn;
    calls.add('$call as ${who ?? 'anon'}');
    await backend.hop();
    return who;
  }

  Room? _roomFor(String id, String? who) => backend.rooms
      .where((r) => r.id == id && r.members.contains(who))
      .firstOrNull;

  Conversation _row(Room r, String who) {
    final last = r.messages.lastOrNull;
    return Conversation(
      id: r.id,
      title: r.title,
      other: r.title != null
          ? null
          : backend.memberOf(r.members.firstWhere((m) => m != who)),
      lastMessage: last?.body,
      lastMessageAt: last?.createdAt,
      lastSenderId: last?.senderId,
    );
  }

  @override
  Future<Result<List<Member>>> members() async {
    final who = await _as('members');
    if (who == null) return const Ok([]);
    return Ok([
      for (final id in backend.profiles.keys)
        if (id != who) backend.memberOf(id),
    ]);
  }

  @override
  Future<Result<List<Conversation>>> conversations() async {
    final who = backend.signedIn;
    final snapshot = who == null
        ? <Conversation>[]
        : [
            for (final r in backend.rooms)
              if (r.members.contains(who)) _row(r, who),
          ];
    await _as('conversations');
    final held = _listHold;
    if (held != null) await held.future;
    return Ok(snapshot);
  }

  @override
  Future<Result<void>> markRead(String conversationId) async {
    final who = await _as('markRead:$conversationId');
    return _roomFor(conversationId, who) == null
        ? const Err(DeniedFailure())
        : const Ok(null);
  }

  @override
  Future<Result<List<Message>>> messages(String conversationId) async {
    final who = await _as('messages:$conversationId');
    return Ok([...?_roomFor(conversationId, who)?.messages]);
  }

  @override
  Future<Result<List<Member>>> conversationMembers(
    String conversationId,
  ) async {
    final who = await _as('conversationMembers:$conversationId');
    final r = _roomFor(conversationId, who);
    return Ok([...?r?.members.map(backend.memberOf)]);
  }

  @override
  Future<Result<List<Message>>> sharedMedia(String conversationId) async {
    final who = await _as('sharedMedia:$conversationId');
    final r = _roomFor(conversationId, who);
    return Ok([...?r?.messages.where((m) => m.hasAttachment)]);
  }

  @override
  Future<Result<List<Message>>> sharedLinks(String conversationId) async {
    final who = await _as('sharedLinks:$conversationId');
    final r = _roomFor(conversationId, who);
    return Ok([...?r?.messages.where((m) => extractLinks(m.body).isNotEmpty)]);
  }

  @override
  Future<Result<Message>> send({
    required String conversationId,
    required String body,
  }) async {
    final who = await _as('send:$conversationId');
    final r = _roomFor(conversationId, who);
    if (r == null) return const Err(DeniedFailure());
    final m = Message(
      id: 'm${r.messages.length + 1}-${r.id}',
      conversationId: r.id,
      senderId: who!,
      body: body.trim(),
      createdAt: DateTime.utc(2026, 9, 24, 9, r.messages.length),
    );
    deliver(m);
    return Ok(m);
  }

  /// Stores [m] and fans it out the way Realtime does: to every live
  /// subscription whose subscriber was a member when it subscribed.
  void deliver(Message m) {
    final r = backend.rooms.firstWhere((r) => r.id == m.conversationId);
    r.messages.add(m);
    for (final s in allSubscriptions) {
      if (r.members.contains(s.as) && s.sink.hasListener) s.sink.add(m);
    }
    for (final s in subscriptions) {
      if (s.id == r.id && r.members.contains(s.as) && s.sink.hasListener) {
        s.sink.add(m);
      }
    }
  }

  @override
  Future<Result<Stream<Message>>> incomingAll() async {
    final who = await _as('incomingAll');
    if (who == null) return const Err(DeniedFailure());
    final sink = StreamController<Message>.broadcast();
    allSubscriptions.add((as: who, sink: sink));
    return Ok(sink.stream);
  }

  @override
  Future<Result<Stream<Message>>> incoming(String conversationId) async {
    final who = await _as('incoming:$conversationId');
    if (who == null) return const Err(DeniedFailure());
    final sink = StreamController<Message>.broadcast();
    subscriptions.add((as: who, id: conversationId, sink: sink));
    return Ok(sink.stream);
  }

  @override
  Future<Result<String>> startDirectConversation(String otherUserId) async {
    final who = await _as('start:$otherUserId');
    if (who == null) return const Err(DeniedFailure());
    final pair = {who, otherUserId};
    final existing = backend.rooms.where(
      (r) =>
          r.title == null &&
          r.members.length == 2 &&
          r.members.containsAll(pair),
    );
    if (existing.isNotEmpty) return Ok(existing.first.id);
    return Ok(backend.room('c-new-${backend.rooms.length}', pair).id);
  }

  @override
  Future<Result<String>> startGroupConversation({
    required String title,
    required List<String> memberIds,
  }) async {
    final who = await _as('group:$title');
    if (who == null) return const Err(DeniedFailure());
    return Ok(
      backend.room('g-${backend.rooms.length}', {
        who,
        ...memberIds,
      }, title: title).id,
    );
  }

  @override
  Future<Result<Message>> sendImage({
    required String conversationId,
    required PickedImage image,
    String body = '',
  }) async => const Err(ProviderFailure('no attachments in this fake'));

  @override
  Future<Result<Uri>> attachmentUrl(String attachmentPath) async {
    final who = await _as('attachmentUrl:$attachmentPath');
    if (who == null) return const Err(DeniedFailure());
    return Ok(Uri.parse('https://x.supabase.co/$attachmentPath?as=$who'));
  }
}

/// [ProfileRepository] pinned to the session holder, as RLS pins it.
class SessionProfile implements ProfileRepository {
  SessionProfile(this.backend);
  final Backend backend;
  final calls = <String>[];

  Future<String?> _as(String call) async {
    final who = backend.signedIn;
    calls.add('$call as ${who ?? 'anon'}');
    await backend.hop();
    return who;
  }

  @override
  Future<Result<OwnProfile>> load() async {
    final who = await _as('load');
    if (who == null) return const Err(DeniedFailure());
    return Ok(backend.profiles[who]!);
  }

  @override
  Future<Result<OwnProfile>> save({
    String? displayName,
    String? tag,
    bool? onboardingDone,
    bool? sharePresence,
    bool? shareTyping,
    bool? shareLastSeen,
  }) async {
    final who = await _as('save');
    if (who == null) return const Err(DeniedFailure());
    final p = backend.profiles[who]!;
    if (tag != null &&
        backend.profiles.entries.any(
          (e) => e.key != who && e.value.tag == tag,
        )) {
      return const Err(ProviderFailure('That tag was just taken by someone.'));
    }
    return Ok(
      backend.profiles[who] = OwnProfile(
        userId: who,
        displayName: displayName ?? p.displayName,
        tag: tag ?? p.tag,
        onboardingDone: onboardingDone ?? p.onboardingDone,
        sharePresence: sharePresence ?? p.sharePresence,
        shareTyping: shareTyping ?? p.shareTyping,
        shareLastSeen: shareLastSeen ?? p.shareLastSeen,
      ),
    );
  }

  @override
  Future<Result<bool>> isTagAvailable(String tag) async {
    final who = await _as('check:$tag');
    return Ok(
      !backend.profiles.entries.any((e) => e.key != who && e.value.tag == tag),
    );
  }
}

/// One online join: who it was made as, and whether it is still held.
class Join {
  Join(this.as, this.share);
  final String? as;
  final bool share;
  bool left = false;
  StreamController<Set<String>>? events;
}

/// [PresenceRepository] over the one session. A channel joined as someone
/// stays joined as them until the caller lets go of it.
class SessionPresence implements PresenceRepository {
  SessionPresence(this.backend);
  final Backend backend;
  final calls = <String>[];
  final joins = <Join>[];
  final typingChannels = <SessionTyping>[];

  /// Members online on other phones.
  Set<String> elsewhere = {};

  List<Join> get live => [
    for (final j in joins)
      if (!j.left) j,
  ];

  Set<String> _online() => {
    ...elsewhere,
    for (final j in live)
      if (j.share && j.as != null) j.as!,
  };

  void _broadcast() {
    for (final j in live) {
      j.events?.add(_online());
    }
  }

  bool _shares(String? who) =>
      who != null && (backend.profiles[who]?.shareLastSeen ?? false);

  Future<String?> _as(String call) async {
    final who = backend.signedIn;
    calls.add('$call as ${who ?? 'anon'}');
    await backend.hop();
    return who;
  }

  @override
  Future<Result<Stream<Set<String>>>> online({required bool share}) async {
    final who = await _as(share ? 'online:share' : 'online:hidden');
    if (who == null) return const Err(DeniedFailure());
    final join = Join(who, share);
    joins.add(join);
    late final StreamController<Set<String>> events;
    events = StreamController<Set<String>>(
      onListen: () => scheduleMicrotask(_broadcast),
      onCancel: () {
        join.left = true;
        _broadcast();
      },
    );
    join.events = events;
    return Ok(events.stream);
  }

  @override
  Future<Result<TypingChannel>> typing(String conversationId) async {
    final who = await _as('typing:$conversationId');
    if (who == null) return const Err(DeniedFailure());
    final c = SessionTyping(conversationId, who);
    typingChannels.add(c);
    return Ok(c);
  }

  @override
  Future<Result<void>> touchLastSeen() async {
    final who = await _as('touch');
    if (_shares(who)) backend.lastSeen[who!] = DateTime.utc(2026, 9, 24, 8);
    return const Ok(null);
  }

  @override
  Future<Result<DateTime?>> lastSeenOf(String userId) async {
    final who = backend.signedIn;
    // Mutual, and answered for whoever asked when the query ran.
    final answer = _shares(who) ? backend.lastSeen[userId] : null;
    await _as('lastSeen:$userId');
    return Ok(answer);
  }
}

class SessionTyping implements TypingChannel {
  SessionTyping(this.conversationId, this.as);
  final String conversationId;
  final String as;
  final _typists = StreamController<String>.broadcast();
  bool closed = false;

  void type(String userId) {
    if (!closed) _typists.add(userId);
  }

  @override
  Stream<String> get typists => _typists.stream;

  @override
  Future<void> signal() async {}

  @override
  Future<void> close() async {
    closed = true;
    await _typists.close();
  }
}

/// The owner's phone: heybana and cagilhay both use it, one after the other.
/// deniz is on another phone. Each of the two has a conversation with deniz
/// the other is not in, and they share one.
const heybana = 'u-heybana';
const cagilhay = 'u-cagilhay';
const deniz = 'u-deniz';

/// Allowlisted nowhere: signs in with Google and is denied.
const stranger = 'u-stranger';

const onlyHeybana = 'only heybana sees this';
const onlyCagilhay = 'only cagilhay sees this';
const shared = 'both of them see this';
final denizSeen = DateTime.utc(2026, 9, 24, 7, 30);

Backend onePhoneTwoAccounts() {
  final b = Backend(
    profiles: const {
      heybana: OwnProfile(
        userId: heybana,
        displayName: 'Heybana',
        tag: 'heybana',
        onboardingDone: true,
      ),
      // Does not share last seen, so last seen is hidden from her: the one
      // answer that differs by who asks.
      cagilhay: OwnProfile(
        userId: cagilhay,
        displayName: 'Cagil Hay',
        tag: 'cagilhay',
        onboardingDone: true,
        shareLastSeen: false,
      ),
      deniz: OwnProfile(
        userId: deniz,
        displayName: 'Deniz',
        tag: 'deniz',
        onboardingDone: true,
      ),
    },
    emails: const {
      heybana: 'heybana@example.org',
      cagilhay: 'cagilhay@example.org',
      deniz: 'deniz@example.org',
    },
  );
  Message m(String room, String from, String body) => Message(
    id: 'seed-$room',
    conversationId: room,
    senderId: from,
    body: body,
    createdAt: DateTime.utc(2026, 9, 24, 6),
  );
  b.room('c-ab', {heybana, cagilhay}).messages.add(m('c-ab', heybana, shared));
  b.room('c-ac', {heybana, deniz}).messages.add(m('c-ac', deniz, onlyHeybana));
  b
      .room('c-bc', {cagilhay, deniz})
      .messages
      .add(m('c-bc', deniz, onlyCagilhay));
  b.lastSeen[deniz] = denizSeen;
  return b;
}
