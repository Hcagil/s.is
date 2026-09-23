/// A signed-in, allowlisted member as shown in the app.
final class Member {
  const Member({
    required this.userId,
    required this.displayName,
    this.tag,
    this.email,
  });

  final String userId;
  final String displayName;

  /// Unique handle, shown as `@tag`. Display names are not unique, so this is
  /// what tells two members with the same name apart.
  final String? tag;

  /// The Google account's address. Known only for the signed-in member
  /// (Settings > Account); never sent for anyone else.
  final String? email;
}
