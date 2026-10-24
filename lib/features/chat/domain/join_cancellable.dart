/// A chat repository whose Realtime join of a single chat can be ended while it is still out (the screen closed first). Optional on purpose: other repositories (fakes) need not implement it.
abstract interface class JoinCancellable {
  /// Ends the pending join of [conversationId]'s channel, if any. No effect once the join has answered.
  void cancelJoin(String conversationId);
}
