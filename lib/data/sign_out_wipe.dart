/// Runs every delete in [deletes] even when an earlier one throws, then rethrows the first error (so a failed delete is still reported, but never skips the others).
Future<void> wipeSignOutKeys(Iterable<Future<void> Function()> deletes) async {
  Object? firstError;
  StackTrace? firstStack;
  for (final d in deletes) {
    try {
      await d();
    } catch (e, s) {
      firstError ??= e;
      firstStack ??= s;
    }
  }
  if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
}
