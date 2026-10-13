part of 'chat_controllers.dart';

/// What the Send a contact picker shows after asking for access.
sealed class PhoneBookState {
  const PhoneBookState();
}

/// Access refused. [permanent]: the system will not prompt again, only the
/// app's settings page helps.
final class PhoneBookDenied extends PhoneBookState {
  const PhoneBookDenied({required this.permanent});
  final bool permanent;
}

/// Access granted: every phone contact that has a number, sorted by name.
final class PhoneBookReady extends PhoneBookState {
  const PhoneBookReady(this.entries);
  final List<PhoneBookEntry> entries;
}

/// The phone contacts for the picker. Asking for the contacts permission
/// happens here, in build(), so only when the picker opens (never earlier).
final phoneBookControllerProvider =
    AsyncNotifierProvider.autoDispose<PhoneBookController, PhoneBookState>(
      PhoneBookController.new,
      retry: _never,
    );

class PhoneBookController extends AsyncNotifier<PhoneBookState> {
  @override
  Future<PhoneBookState> build() async {
    final book = ref.read(phoneBookProvider);
    return switch (await book.requestAccess()) {
      PhoneBookAccess.granted => PhoneBookReady(await book.entries()),
      PhoneBookAccess.denied => const PhoneBookDenied(permanent: false),
      PhoneBookAccess.permanentlyDenied => const PhoneBookDenied(
        permanent: true,
      ),
    };
  }

  /// Asks again (the "Allow access" button); a permanent refusal opens the
  /// app's settings page instead.
  Future<void> retryAccess() async {
    final current = state.value;
    if (current is PhoneBookDenied && current.permanent) {
      await ref.read(phoneBookProvider).openSettings();
      return;
    }
    ref.invalidateSelf();
  }
}
