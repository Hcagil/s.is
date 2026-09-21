/// A signed-in, allowlisted member as shown in the app.
final class Member {
  const Member({required this.userId, required this.displayName});

  final String userId;
  final String displayName;
}
