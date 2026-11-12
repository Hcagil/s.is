import '../../../core/failure.dart';
import 'admin_answer.dart';
import 'admin_item.dart';

/// Where this phone stands in linking with the computer.
enum AdminLinkPhase {
  /// No key on this phone yet, or it was never published.
  unlinked,

  /// Key published; the computer has not published its key yet.
  waiting,

  /// Both keys known: the 60-digit code is shown and the owner has not tapped Matches.
  confirm,

  /// The computer key was confirmed and still is the same.
  linked,

  /// The computer key the phone confirmed earlier is not the one on the server now.
  changed,
}

/// The link state plus what the Link screen needs.
final class AdminStatus {
  const AdminStatus(this.phase, {this.code, this.epoch = 0});
  final AdminLinkPhase phase;

  /// 60 digits, only in phase confirm.
  final String? code;

  /// The server's key epoch (0 = none yet).
  final int epoch;
}

/// One row the computer sent, already opened (null when it could not be opened or is not a known message).
final class AdminRow {
  const AdminRow({
    required this.id,
    required this.epoch,
    required this.seq,
    required this.message,
  });
  final int id;
  final int epoch;
  final int seq;
  final AdminDown? message;
}

enum AdminUnlockResult { ok, noLock, cancelled }

/// Asks the owner to unlock the phone (fingerprint, face or PIN) before the panels open.
abstract interface class AdminUnlock {
  /// [reason] is shown by the system dialog.
  Future<AdminUnlockResult> authenticate(String reason);
}

/// The owner-only panels on the server: linking status, down rows, up messages.
abstract interface class AdminPanelsRepository {
  /// null = this account is not the owner (the server returned no row).
  Future<Result<AdminStatus?>> status();

  /// Makes this phone's key pair if none and publishes its public key.
  Future<Result<AdminStatus>> startLink();

  /// The owner tapped Matches: pins the computer key shown in the code.
  Future<Result<AdminStatus>> confirmLink();

  /// Down rows after [afterId], opened and checked.
  Future<Result<List<AdminRow>>> fetch(int afterId);

  /// Seals the JSON map as an up message with the next sequence number and sends it; the Ok value says which row it was.
  Future<Result<AdminSentRef?>> send(Map<String, Object?> message);

  /// The highest down sequence this phone applied for [epoch].
  Future<int> lastDownSeq(int epoch);

  /// Saves [seq] as the highest down sequence applied for [epoch].
  Future<void> saveLastDownSeq(int epoch, int seq);

  /// Deletes the key, the pinned key and the counters (sign-out).
  Future<void> forget();
}
