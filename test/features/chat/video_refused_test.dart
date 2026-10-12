// videoRefusedProvider: the message ids whose video refused to play, kept in
// memory only, per message, and forgotten when the signed-in user changes.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/application/session_controller.dart';
import 'package:sis/features/chat/application/video_refused.dart';

class _Account extends CurrentUserId {
  @override
  String? build() => 'u1';
  void switchTo(String? id) => state = id;
}

void main() {
  late ProviderContainer c;
  setUp(() {
    c = ProviderContainer.test(
      overrides: [currentUserIdProvider.overrideWith(_Account.new)],
    );
    c.listen(videoRefusedProvider, (_, _) {});
  });

  Set<String> refused() => c.read(videoRefusedProvider);
  void refuse(String id) => c.read(videoRefusedProvider.notifier).refuse(id);
  void switchTo(String? id) =>
      (c.read(currentUserIdProvider.notifier) as _Account).switchTo(id);

  test('starts empty and remembers each refused message on its own', () {
    expect(refused(), isEmpty);
    refuse('m1');
    expect(refused(), {'m1'});
    refuse('m2');
    refuse('m1');
    expect(refused(), {'m1', 'm2'});
  });

  test('another user signing in starts from nothing', () {
    refuse('m1');
    switchTo('u2');
    expect(refused(), isEmpty);
  });

  test('signing out forgets too', () {
    refuse('m1');
    switchTo(null);
    expect(refused(), isEmpty);
  });

  test('a new container (app restart) starts empty: memory only', () {
    refuse('m1');
    final fresh = ProviderContainer.test(
      overrides: [currentUserIdProvider.overrideWith(_Account.new)],
    );
    expect(fresh.read(videoRefusedProvider), isEmpty);
  });
}
