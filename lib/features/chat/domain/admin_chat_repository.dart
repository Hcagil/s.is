import '../../../core/failure.dart';

/// Admin chat boundary; the only way the app answers a card in the admin chat. A repository never throws: a refusal arrives as [Err] with a typed [Failure].
abstract interface class AdminChatRepository {
  /// Answers the confirmation card [cardId]: [yes] removes the tester, otherwise cancels. DeniedFailure when the caller is not the owner.
  Future<Result<void>> answer(String cardId, bool yes);
}
