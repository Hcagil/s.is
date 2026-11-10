/// Tells the server five facts about this phone (model, OS version, app
/// version, build number, install source) so support can help; never the
/// phone's name or any id. Best effort: never throws, retried at next start.
abstract interface class DeviceReporter {
  Future<void> report();
}
