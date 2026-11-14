import '../../../core/failure.dart';
import '../domain/admin_answer.dart';
import '../domain/admin_marks.dart';
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

  /// The newest answer of [kind] for [id] (a question or task id; for talk the conversation id, null = no conversation).
  AdminAnswer? latestAnswer(String kind, {String? id}) {
    for (final a in answers.reversed) {
      if (a.kind != kind) continue;
      if ((kind == 'talk' ? a.conv : a.targetId) == id) return a;
    }
    return null;
  }

  /// How many items are new on each tab (keys talk, questions, tasks).
  Map<String, int> get newCounts => adminNewCounts(snapshot, seen);

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
    );
  }
}
