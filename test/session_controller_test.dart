import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/session_controller.dart';

void main() {
  test('activates an allowed session and loads members', () async {
    final authChanges = StreamController<bool>();
    final controller = SessionController.connected(
      initiallySignedIn: true,
      signedInChanges: authChanges.stream,
      activateSession: () async => true,
      loadMemberProfiles: () async => const [
        MemberProfile(userId: 'member-id', displayName: 'Maya'),
      ],
      startGoogleSignIn: () async => true,
      performSignOut: () async {},
    );

    await Future<void>.delayed(Duration.zero);

    expect(controller.status, SessionStatus.allowed);
    expect(controller.members.single.displayName, 'Maya');
    controller.dispose();
    await authChanges.close();
  });

  test('clears protected state when the session is replaced', () async {
    final authChanges = StreamController<bool>();
    final controller = SessionController.connected(
      initiallySignedIn: true,
      signedInChanges: authChanges.stream,
      activateSession: () async => true,
      loadMemberProfiles: () async => const [
        MemberProfile(userId: 'member-id', displayName: 'Maya'),
      ],
      startGoogleSignIn: () async => true,
      performSignOut: () async {},
    );
    await Future<void>.delayed(Duration.zero);

    authChanges.add(false);
    await Future<void>.delayed(Duration.zero);

    expect(controller.status, SessionStatus.signedOut);
    expect(controller.members, isEmpty);
    controller.dispose();
    await authChanges.close();
  });

  test('returns to signed out when Google sign-in is canceled', () async {
    final authChanges = StreamController<bool>();
    final controller = SessionController.connected(
      initiallySignedIn: false,
      signedInChanges: authChanges.stream,
      activateSession: () async => true,
      loadMemberProfiles: () async => const [],
      startGoogleSignIn: () async => false,
      performSignOut: () async {},
    );
    await Future<void>.delayed(Duration.zero);

    await controller.signIn();

    expect(controller.status, SessionStatus.signedOut);
    controller.dispose();
    await authChanges.close();
  });
}
