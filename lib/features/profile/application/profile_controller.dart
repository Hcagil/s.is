import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../domain/own_profile.dart';
import '../domain/profile_repository.dart';

final profileRepositoryProvider = Provider<ProfileRepository>(
  (_) => throw UnimplementedError('override in main'),
);

/// Riverpod 3 would otherwise retry a failed build forever and never settle
/// on an error the screen can show (see chat_controllers.dart).
Duration? _never(int retryCount, Object error) => null;

/// The signed-in member's own profile.
///
/// autoDispose: the session gate stops watching it on sign-out, so the next
/// member to sign in on this phone never sees the previous member's profile.
final ownProfileProvider =
    AsyncNotifierProvider.autoDispose<OwnProfileController, OwnProfile>(
      OwnProfileController.new,
      retry: _never,
    );

class OwnProfileController extends AsyncNotifier<OwnProfile> {
  @override
  Future<OwnProfile> build() async =>
      switch (await ref.read(profileRepositoryProvider).load()) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };

  Future<void> retry() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(build);
  }

  /// Saves a new name and/or tag. On failure the profile on screen is left
  /// as it was and the reason is returned for the form to show.
  Future<Result<OwnProfile>> save({String? displayName, String? tag}) =>
      _save(displayName: displayName, tag: tag);

  /// Leaves the first-run screen. With no arguments the member keeps the
  /// name from their Google account and the generated tag.
  Future<Result<OwnProfile>> completeOnboarding({
    String? displayName,
    String? tag,
  }) => _save(displayName: displayName, tag: tag, onboardingDone: true);

  Future<Result<OwnProfile>> _save({
    String? displayName,
    String? tag,
    bool? onboardingDone,
  }) async {
    final result = await ref
        .read(profileRepositoryProvider)
        .save(
          displayName: displayName,
          tag: tag,
          onboardingDone: onboardingDone,
        );
    if (result case Ok(:final value) when ref.mounted) {
      state = AsyncData(value);
    }
    return result;
  }

  /// Advisory availability for the tag field.
  Future<Result<bool>> checkTag(String tag) =>
      ref.read(profileRepositoryProvider).isTagAvailable(tag);
}
