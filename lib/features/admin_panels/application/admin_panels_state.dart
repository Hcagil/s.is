import '../../../core/failure.dart';
import '../domain/admin_answer.dart';
import '../domain/admin_marks.dart';
import '../domain/admin_models.dart';
import '../domain/admin_panels_repository.dart';
import '../domain/admin_snapshot.dart';

/// What the admin panels screen shows.
enum AdminGate {
  /// Asking the phone unlock, then the server.
  checking,

  /// The owner dismissed the phone unlock.
  cancelled,

  /// The phone has no screen lock.
  noLock,

  /// This account is not the owner (the screen shows nothing).
  notOwner,

  /// The link screen (see [AdminPanelsState.link]).
  link,

  /// Linked: the four panels.
  ready,

  /// The server or the network failed (see [AdminPanelsState.failure]).
  failed,
}

/// The link to the computer as the polls show it.
enum AdminConn {
  /// A poll round is running and none has worked since the screen opened.
  connecting,

  /// The last round worked.
  connected,

  /// The last round failed (stays so until a round works).
  offline,
}

/// The whole state of the admin panels while the screen is open.
final class AdminPanelsState {
  const AdminPanelsState({
    this.gate = AdminGate.checking,
    this.link,
    this.snapshot = AdminSnapshot.empty,
    this.hasSnapshot = false,
    this.syncing = false,
    this.failure,
    this.sentQuestions = const {},
    this.decidedTasks = const {},
    this.linkBusy = false,
    this.answers = const [],
    this.seen,
    this.conn = AdminConn.connecting,
    this.readUpto = const {},
    this.pinOverride = const {},
  });

  final AdminGate gate;

  /// The link status while [gate] is link.
  final AdminStatus? link;
  final AdminSnapshot snapshot;

  /// What the icon in the top bar shows.
  final AdminConn conn;

  /// True once one complete snapshot has arrived (the panels show data only then).
  final bool hasSnapshot;

  /// A full resync was asked and has not arrived yet.
  final bool syncing;
  final Failure? failure;

  /// Question ids answered on this phone (shown as waiting until the computer drops them).
  final Set<String> sentQuestions;

  /// Task ids decided on this phone (hidden).
  final Set<String> decidedTasks;

  /// A link step is running.
  final bool linkBusy;

  /// Answers sent from this phone and their delivery state (memory only).
  final List<AdminAnswer> answers;

  /// Item ids already seen per tab (talk, questions, tasks); null until loaded.
  final Map<String, Set<String>>? seen;

  /// Per conversation id: the newest message time (computer seconds) the owner read on this phone.
  final Map<String, int> readUpto;

  /// Per conversation id: the pin state the owner just chose on this phone, until a snapshot confirms it.
  final Map<String, bool> pinOverride;

  /// Whether [c] shows as pinned: the owner's fresh choice first, else the computer's value.
  bool isPinned(AdminConversation c) => pinOverride[c.id] ?? c.isPinned;

  /// The Talk list order: pinned block first, earliest pinned first (a pin with no time yet goes last in the block); the rest keep the snapshot order.
  List<AdminConversation> get talkOrder {
    final pinned = [
      for (final c in snapshot.conversations)
        if (isPinned(c)) c,
    ];
    // Stable: equal times (and the not-yet-timed ones, 0 -> last) keep snapshot order.
    final idx = {for (final (i, c) in pinned.indexed) c.id: i};
    pinned.sort((a, b) {
      final ka = a.pinnedAt > 0 ? a.pinnedAt : 1 << 62;
      final kb = b.pinnedAt > 0 ? b.pinnedAt : 1 << 62;
      return ka != kb ? ka.compareTo(kb) : idx[a.id]!.compareTo(idx[b.id]!);
    });
    return [
      ...pinned,
      for (final c in snapshot.conversations)
        if (!isPinned(c)) c,
    ];
  }

  /// The newest answer of [kind] for [id] (a question or task id; for talk the conversation id, null = no conversation).
  AdminAnswer? latestAnswer(String kind, {String? id}) {
    for (final a in answers.reversed) {
      if (a.kind != kind) continue;
      if ((kind == 'talk' ? a.conv : a.targetId) == id) return a;
    }
    return null;
  }

  /// Questions the owner has not answered yet (same test as the Questions tab: not waiting, not sent from this phone).
  int get unansweredQuestions => snapshot.questions
      .where((q) => !q.waiting && !sentQuestions.contains(q.id))
      .length;

  /// How many items are new on each tab (keys talk, questions, tasks).
  Map<String, int> get newCounts => adminNewCounts(snapshot, seen, readUpto);

  AdminPanelsState copyWith({
    AdminGate? gate,
    AdminStatus? link,
    AdminSnapshot? snapshot,
    bool? hasSnapshot,
    bool? syncing,
    Failure? failure,
    Set<String>? sentQuestions,
    Set<String>? decidedTasks,
    bool? linkBusy,
    List<AdminAnswer>? answers,
    Map<String, Set<String>>? seen,
    AdminConn? conn,
    Map<String, int>? readUpto,
    Map<String, bool>? pinOverride,
    bool clearSeen = false,
    bool clearFailure = false,
  }) {
    return AdminPanelsState(
      gate: gate ?? this.gate,
      link: link ?? this.link,
      snapshot: snapshot ?? this.snapshot,
      hasSnapshot: hasSnapshot ?? this.hasSnapshot,
      syncing: syncing ?? this.syncing,
      failure: clearFailure ? null : (failure ?? this.failure),
      sentQuestions: sentQuestions ?? this.sentQuestions,
      decidedTasks: decidedTasks ?? this.decidedTasks,
      linkBusy: linkBusy ?? this.linkBusy,
      answers: answers ?? this.answers,
      seen: clearSeen ? null : (seen ?? this.seen),
      conn: conn ?? this.conn,
      readUpto: readUpto ?? this.readUpto,
      pinOverride: pinOverride ?? this.pinOverride,
    );
  }
}
