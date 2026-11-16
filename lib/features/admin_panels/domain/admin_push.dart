import '../../../core/failure.dart';

/// A nudge from the server that a new down row exists; carries no data.
abstract interface class AdminPush {
  /// Joins the private 'admin_view' channel; the stream emits one event per server push; cancelling the stream leaves the channel. Err when the join fails (the poll keeps working).
  Future<Result<Stream<void>>> listen();
}

/// Used until main overrides it, and in tests: never pushes.
final class NoAdminPush implements AdminPush {
  const NoAdminPush();

  @override
  Future<Result<Stream<void>>> listen() async => const Ok(Stream<void>.empty());
}
