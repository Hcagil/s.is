sealed class Failure {
  const Failure();

  String get message;
}

final class NetworkFailure extends Failure {
  const NetworkFailure(this.message);

  @override
  final String message;
}

final class DeniedFailure extends Failure {
  const DeniedFailure();

  @override
  String get message => 'Not allowed';
}

final class ProviderFailure extends Failure {
  const ProviderFailure(this.message, {this.userCanceled = false});

  @override
  final String message;
  final bool userCanceled;
}

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
