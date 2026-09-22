/// The signed-in member's own profile: what onboarding and settings edit.
final class OwnProfile {
  const OwnProfile({
    required this.userId,
    required this.displayName,
    required this.tag,
    required this.onboardingDone,
  });

  final String userId;
  final String displayName;

  /// Unique handle, shown as `@tag`. Always present: one is generated from the
  /// name at sign-up.
  final String tag;

  /// False until the member has seen the name-and-tag screen once.
  final bool onboardingDone;
}

/// Longest display name the database accepts.
const int maxDisplayNameLength = 80;

/// The tag as it would be stored: trimmed, without a leading `@`, lower-case.
String normaliseTag(String input) {
  final trimmed = input.trim();
  final bare = trimmed.startsWith('@') ? trimmed.substring(1) : trimmed;
  return bare.toLowerCase();
}

/// Why [tag] (already normalised) cannot be used, or null when its shape is
/// fine. The same shape as the `profiles.tag` check constraint; whether it is
/// FREE is a separate question only the server can answer.
String? tagProblem(String tag) {
  if (tag.length < 3) return 'At least 3 characters';
  if (tag.length > 20) return 'At most 20 characters';
  if (!RegExp(r'^[a-z]').hasMatch(tag)) return 'Start with a letter';
  if (!RegExp(r'^[a-z0-9_]+$').hasMatch(tag)) {
    return 'Letters, digits and _ only';
  }
  return null;
}

/// Why [name] cannot be used as a display name, or null when it can.
String? displayNameProblem(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'Enter a name';
  if (trimmed.length > maxDisplayNameLength) {
    return 'At most $maxDisplayNameLength characters';
  }
  return null;
}
