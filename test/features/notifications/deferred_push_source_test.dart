// DeferredPushSource (0.30.14), from its contract: every call waits for the
// push setup and then delegates; nothing is dropped; a failed setup fails
// each call on its own.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/notifications/data/deferred_push_source.dart';
import 'package:sis/features/notifications/domain/push.dart';

/// A minimal fake implementation of [PushSource] that records all calls
/// and exposes stream controllers for testing stream behaviour.
class FakePushSource implements PushSource {
  final List<void> _requestPermissionCalls = [];
  final List<void> _permissionStatusCalls = [];
  final List<void> _tokenCalls = [];
  final List<void> _launchConversationCalls = [];
  final List<String> _clearConversationCalls = [];
  final List<void> _clearAllCalls = [];
  final List<String?> _forUserCalls = [];

  final StreamController<String> _tokenRefreshesController =
      StreamController<String>.broadcast();
  final StreamController<String> _openedConversationsController =
      StreamController<String>.broadcast();

  @override
  Future<bool> requestPermission() async {
    _requestPermissionCalls.add(null);
    return true;
  }

  @override
  Future<PushPermissionStatus> permissionStatus() async {
    _permissionStatusCalls.add(null);
    return PushPermissionStatus.values.last;
  }

  @override
  Future<String?> token() async {
    _tokenCalls.add(null);
    return 'token123';
  }

  @override
  Stream<String> get tokenRefreshes => _tokenRefreshesController.stream;

  @override
  Future<String?> launchConversation() async {
    _launchConversationCalls.add(null);
    return 'conv123';
  }

  @override
  Stream<String> get openedConversations =>
      _openedConversationsController.stream;

  @override
  Future<void> clearConversation(String conversationId) async {
    _clearConversationCalls.add(conversationId);
  }

  @override
  Future<void> clearAll() async {
    _clearAllCalls.add(null);
  }

  @override
  Future<void> forUser(String? userId) async {
    _forUserCalls.add(userId);
  }

  // Expose the controllers so tests can push events.
  StreamController<String> get tokenRefreshesController =>
      _tokenRefreshesController;
  StreamController<String> get openedConversationsController =>
      _openedConversationsController;

  // Helpers to inspect recorded calls.
  int get requestPermissionCount => _requestPermissionCalls.length;
  int get permissionStatusCount => _permissionStatusCalls.length;
  int get tokenCount => _tokenCalls.length;
  int get launchConversationCount => _launchConversationCalls.length;
  int get clearConversationCount => _clearConversationCalls.length;
  int get clearAllCount => _clearAllCalls.length;
  int get forUserCount => _forUserCalls.length;
  List<String?> get forUserCalls => List.unmodifiable(_forUserCalls);
  List<String> get clearConversationCalls =>
      List.unmodifiable(_clearConversationCalls);
}

/// Tests for the contract of [DeferredPushSource].
void main() {
  group('DeferredPushSource', () {
    test('forwards calls made before ready completes', () async {
      final readyCompleter = Completer<PushSource>();
      final source = DeferredPushSource(readyCompleter.future);

      // Call all methods before ready completes.
      final requestPermissionFuture = source.requestPermission();
      final permissionStatusFuture = source.permissionStatus();
      final tokenFuture = source.token();
      final launchConversationFuture = source.launchConversation();
      final clearConversationFuture = source.clearConversation('c1');
      final clearAllFuture = source.clearAll();
      final forUserFuture1 = source.forUser('u1');
      final forUserFuture2 = source.forUser(null);

      // Listen to streams before ready completes.
      final tokenRefreshesEvents = <String>[];
      final openedConversationsEvents = <String>[];
      source.tokenRefreshes.listen(tokenRefreshesEvents.add);
      source.openedConversations.listen(openedConversationsEvents.add);

      // Nothing resolves while setup is still running.
      var settledEarly = false;
      unawaited(launchConversationFuture.then((_) => settledEarly = true));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(settledEarly, isFalse, reason: 'must wait for the setup');

      // Create the fake source and complete the ready future.
      final fake = FakePushSource();
      readyCompleter.complete(fake);

      // Await all futures.
      final requestPermissionResult = await requestPermissionFuture;
      final permissionStatusResult = await permissionStatusFuture;
      final tokenResult = await tokenFuture;
      final launchConversationResult = await launchConversationFuture;
      await clearConversationFuture;
      await clearAllFuture;
      await forUserFuture1;
      await forUserFuture2;

      // Verify that the fake recorded all calls.
      expect(fake.requestPermissionCount, 1);
      expect(fake.permissionStatusCount, 1);
      expect(fake.tokenCount, 1);
      expect(fake.launchConversationCount, 1);
      expect(fake.clearConversationCount, 1);
      expect(fake.clearAllCount, 1);
      expect(fake.forUserCount, 2);
      expect(fake.forUserCalls, ['u1', null]);
      expect(fake.clearConversationCalls, ['c1']);

      // Verify returned values.
      expect(requestPermissionResult, isTrue);
      expect(permissionStatusResult, PushPermissionStatus.values.last);
      expect(tokenResult, 'token123');
      expect(launchConversationResult, 'conv123');

      // Emit events after ready completes.
      fake.tokenRefreshesController.add('refresh1');
      fake.openedConversationsController.add('convOpen1');
      await Future.delayed(Duration.zero); // allow events to propagate

      // Verify that listeners received the events.
      expect(tokenRefreshesEvents, ['refresh1']);
      expect(openedConversationsEvents, ['convOpen1']);
    });

    test('forwards calls made after ready completes', () async {
      final readyCompleter = Completer<PushSource>();
      final source = DeferredPushSource(readyCompleter.future);
      final fake = FakePushSource();
      readyCompleter.complete(fake);

      // Call methods after ready.
      final requestPermissionResult = await source.requestPermission();
      final permissionStatusResult = await source.permissionStatus();
      final tokenResult = await source.token();
      final launchConversationResult = await source.launchConversation();
      await source.clearConversation('c2');
      await source.clearAll();
      await source.forUser('u2');
      await source.forUser(null);

      // Verify that the fake recorded all calls.
      expect(fake.requestPermissionCount, 1);
      expect(fake.permissionStatusCount, 1);
      expect(fake.tokenCount, 1);
      expect(fake.launchConversationCount, 1);
      expect(fake.clearConversationCount, 1);
      expect(fake.clearAllCount, 1);
      expect(fake.forUserCount, 2);
      expect(fake.forUserCalls, ['u2', null]);
      expect(fake.clearConversationCalls, ['c2']);

      // Verify returned values.
      expect(requestPermissionResult, isTrue);
      expect(permissionStatusResult, PushPermissionStatus.values.last);
      expect(tokenResult, 'token123');
      expect(launchConversationResult, 'conv123');
    });

    test('propagates error from ready to all calls', () async {
      final readyCompleter = Completer<PushSource>();
      final source = DeferredPushSource(readyCompleter.future);
      final error = Exception('setup failed');

      // Call methods before ready completes.
      final requestPermissionFuture = source.requestPermission();
      final permissionStatusFuture = source.permissionStatus();
      final tokenFuture = source.token();
      final launchConversationFuture = source.launchConversation();
      final clearConversationFuture = source.clearConversation('c3');
      final clearAllFuture = source.clearAll();
      final forUserFuture1 = source.forUser('u3');
      final forUserFuture2 = source.forUser(null);

      // Listen to streams before ready completes.
      final tokenRefreshesError = expectLater(
        source.tokenRefreshes,
        emitsError(error),
      );
      final openedConversationsError = expectLater(
        source.openedConversations,
        emitsError(error),
      );

      // Complete ready with an error.
      readyCompleter.completeError(error);

      // All futures should throw the same error.
      await expectLater(requestPermissionFuture, throwsA(error));
      await expectLater(permissionStatusFuture, throwsA(error));
      await expectLater(tokenFuture, throwsA(error));
      await expectLater(launchConversationFuture, throwsA(error));
      await expectLater(clearConversationFuture, throwsA(error));
      await expectLater(clearAllFuture, throwsA(error));
      await expectLater(forUserFuture1, throwsA(error));
      await expectLater(forUserFuture2, throwsA(error));

      // Streams should emit the error.
      await tokenRefreshesError;
      await openedConversationsError;

      // Subsequent calls after error should also fail.
      await expectLater(source.requestPermission(), throwsA(error));
      await expectLater(source.permissionStatus(), throwsA(error));
      await expectLater(source.token(), throwsA(error));
      await expectLater(source.launchConversation(), throwsA(error));
      await expectLater(source.clearConversation('c4'), throwsA(error));
      await expectLater(source.clearAll(), throwsA(error));
      await expectLater(source.forUser('u4'), throwsA(error));
      await expectLater(source.forUser(null), throwsA(error));
    });
  });
}
