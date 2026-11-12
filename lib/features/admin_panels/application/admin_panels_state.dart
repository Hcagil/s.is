import '../../../core/failure.dart';
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
  });

  final AdminGate gate;

  /// The link status while [gate] is link.
  final AdminStatus? link;
  final AdminSnapshot snapshot;

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
    );
  }
}
