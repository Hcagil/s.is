import 'member.dart';

/// The "last confirmed session" marker: lets a cold start show the stored chat
/// list before the server answers. Holds no token and no email -- only who
/// was confirmed, on which session, and when.
final class LastSession {
  const LastSession({
    required this.userId,
    required this.sessionId,
    required this.me,
    required this.onboarded,
    required this.confirmedAt,
  });

  /// The auth user id.
  final String userId;

  /// The `session_id` claim of the access token this was confirmed for.
  final String sessionId;

  /// The confirmed member, stored through [Member.toJson] (never the email).
  final Member me;

  /// Whether the member had finished the first-run screen.
  final bool onboarded;

  /// When the server last answered "allowed".
  final DateTime confirmedAt;

  LastSession copyWith({Member? me, bool? onboarded, DateTime? confirmedAt}) =>
      LastSession(
        userId: userId,
        sessionId: sessionId,
        me: me ?? this.me,
        onboarded: onboarded ?? this.onboarded,
        confirmedAt: confirmedAt ?? this.confirmedAt,
      );

  Map<String, Object?> toJson() => {
    'userId': userId,
    'sessionId': sessionId,
    'me': me.toJson(),
    'onboarded': onboarded,
    'confirmedAt': confirmedAt.toUtc().toIso8601String(),
  };

  /// Throws on a malformed map; the store catches and treats it as no marker.
  static LastSession fromJson(Map<String, Object?> json) => LastSession(
    userId: json['userId'] as String,
    sessionId: json['sessionId'] as String,
    me: Member.fromJson(json['me'] as Map<String, Object?>),
    onboarded: json['onboarded'] as bool,
    confirmedAt: DateTime.parse(json['confirmedAt'] as String),
  );
}

/// How long a marker may stand in for the server's answer.
const lastSessionMaxAge = Duration(days: 14);

/// Where the marker lives on the phone. Every method is best-effort and never
/// throws.
abstract interface class LastSessionStore {
  /// The saved marker, or null when none, unreadable, corrupt or of another
  /// schema (a bad file is deleted).
  Future<LastSession?> load();

  /// Replaces the marker.
  Future<void> save(LastSession session);

  /// Removes the marker, if any. A save in flight must not resurrect it.
  Future<void> clear();
}
