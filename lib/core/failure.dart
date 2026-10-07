sealed class Failure {
  const Failure();

  String get message;
}

final class NetworkFailure extends Failure {
  const NetworkFailure(this.message, {this.retryable = false});

  @override
  final String message;

  /// Whether this is worth retrying without asking the member again: no
  /// connection or the server did not answer in time, rather than the
  /// server answering with a refusal. Set by `readableFailure` in
  /// `lib/data/failures.dart`, the one place that classifies an SDK error.
  final bool retryable;
}

final class DeniedFailure extends Failure {
  const DeniedFailure();

  @override
  String get message => 'Not allowed';
}

/// Pinning a sixth chat; the screen shows its own translated line.
final class PinLimitFailure extends Failure {
  const PinLimitFailure();

  @override
  String get message => 'You can pin up to 5 chats.';
}

final class ProviderFailure extends Failure {
  const ProviderFailure(this.message, {this.userCanceled = false});

  @override
  final String message;
  final bool userCanceled;
}

/// Words for any error a screen shows: a Failure's own message, never a raw
/// SDK error (a platform plugin's text must not reach the member).
String failureReason(Object error) =>
    error is Failure ? error.message : 'Something went wrong. Try again.';

sealed class Result<T> {
  const Result();
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.failure);

  final Failure failure;
}
