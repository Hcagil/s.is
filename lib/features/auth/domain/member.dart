/// A signed-in, allowlisted member as shown in the app.
final class Member {
  const Member({
    required this.userId,
    required this.displayName,
    this.tag,
    this.email,
    this.avatarPath,
  });

  final String userId;
  final String displayName;

  /// Unique handle, shown as `@tag`. Display names are not unique, so this is
  /// what tells two members with the same name apart.
  final String? tag;

  /// The Google account's address. Known only for the signed-in member
  /// (Settings > Account); never sent for anyone else.
  final String? email;

  /// Storage path of their picture, or null for none.
  final String? avatarPath;

  /// For the on-disk chat list snapshot only. Deliberately omits [email]:
  /// that is never written to storage.
  Map<String, Object?> toJson() => {
    'id': userId,
    'name': displayName,
    'tag': tag,
    'avatar': avatarPath,
  };

  static Member fromJson(Map<String, Object?> json) => Member(
    userId: json['id'] as String,
    displayName: json['name'] as String,
    tag: json['tag'] as String?,
    avatarPath: json['avatar'] as String?,
  );
}
