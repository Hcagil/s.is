/// The language failure texts are written in: 'tr' is Turkish, anything else English. The app sets it from the language it shows (SisApp builder).
String failureLanguage = 'en';

/// [en] or [tr] by [failureLanguage].
String failureText(String en, String tr) => failureLanguage == 'tr' ? tr : en;

sealed class Failure {
  const Failure();

  String get message;
}

final class NetworkFailure extends Failure {
  const NetworkFailure(this.message, {this.retryable = false});

  /// A fixed text in both languages (the data layer passes two literals, never error text).
  factory NetworkFailure.localized(
    String en,
    String tr, {
    bool retryable = false,
  }) => NetworkFailure(failureText(en, tr), retryable: retryable);

  @override
  final String message;

  /// Whether this is worth retrying without asking the member again: no
  /// connection or the server did not answer in time, rather than the
  /// server answering with a refusal. Set by `readableFailure` in
  /// `lib/data/failures.dart`, the one place that classifies an SDK error.
  final bool retryable;
}

final class DeniedFailure extends Failure {
  const DeniedFailure();

  @override
  String get message => failureText(
    "You don't have permission to do that.",
    'Bunu yapma iznin yok.',
  );
}

/// A server search limit hit ('RLMT1'); the screen shows its own line.
final class SearchLimitFailure extends Failure {
  const SearchLimitFailure();

  @override
  String get message => failureText(
    'Too many searches. Try again in a little while.',
    'Çok fazla arama yaptın. Biraz sonra tekrar dene.',
  );
}

/// A sticker limit hit on the server: 'STKA1' (10 albums), 'STKA2' (50 stickers in an album) or 'STKF1' (200 favourites); the screen shows its own translated line.
final class StickerLimitFailure extends Failure {
  const StickerLimitFailure(this.code);

  /// The server's error code: STKA1, STKA2 or STKF1.
  final String code;

  @override
  String get message => failureText(
    'You have reached the sticker limit.',
    'Çıkartma sınırına ulaştın.',
  );
}

/// The picture could not be turned into a sticker, or the upload failed to start.
final class StickerMakeFailure extends Failure {
  const StickerMakeFailure();

  @override
  String get message =>
      failureText('Could not create the sticker.', 'Çıkartma oluşturulamadı.');
}

/// Pinning a sixth chat; the screen shows its own translated line.
final class PinLimitFailure extends Failure {
  const PinLimitFailure();

  @override
  String get message => failureText(
    'You can pin up to 5 chats.',
    'En fazla 5 sohbet sabitleyebilirsin.',
  );
}

/// Voting in a poll that has been closed; the screen shows its own translated line.
final class PollClosedFailure extends Failure {
  const PollClosedFailure();

  @override
  String get message =>
      failureText('This poll is closed.', 'Bu anket kapandı.');
}

/// A video still over the 50 MiB limit after it was shrunk; the screen shows its own translated line.
final class VideoTooBigFailure extends Failure {
  const VideoTooBigFailure();

  @override
  String get message => failureText(
    'This video is too large to send.',
    'Bu video gönderilemeyecek kadar büyük.',
  );
}

/// Shrinking the video failed; the screen shows its own translated line.
final class VideoFailedFailure extends Failure {
  const VideoFailedFailure();

  @override
  String get message => failureText(
    'This video could not be prepared.',
    'Bu video hazırlanamadı.',
  );
}

/// The member cancelled the shrinking; never shown.
final class VideoCancelledFailure extends Failure {
  const VideoCancelledFailure();

  @override
  String get message => failureText('Canceled.', 'İptal edildi.');
}

/// Location permission was refused; the screen shows its own translated line. [forever] is true when only the phone settings can change it.
final class LocationDeniedFailure extends Failure {
  const LocationDeniedFailure({this.forever = false});

  final bool forever;

  @override
  String get message =>
      failureText('Location is turned off for SIS.', 'SIS için konum kapalı.');
}

/// Location is switched off on the phone or no position arrived in time; the screen shows its own translated line.
final class LocationUnavailableFailure extends Failure {
  const LocationUnavailableFailure();

  @override
  String get message =>
      failureText('Could not find where you are.', 'Konumun bulunamadı.');
}

final class ProviderFailure extends Failure {
  const ProviderFailure(this.message, {this.userCanceled = false});

  @override
  final String message;
  final bool userCanceled;
}

/// Apple gave a hidden (private relay) email; SIS needs the real one. The sign-in screen shows its own translated line.
final class HiddenEmailFailure extends Failure {
  const HiddenEmailFailure();

  @override
  String get message => failureText(
    "SIS needs your real email address. In Apple's sign-in choose Share My Email and try again.",
    "SIS gerçek e-posta adresini gerektirir. Apple ile oturum açarken E-postamı Paylaş'ı seçip tekrar dene.",
  );
}

/// A chat partner's published keys failed their signature check; no session is opened.
final class DeviceKeysFailure extends Failure {
  const DeviceKeysFailure();

  @override
  String get message => failureText(
    "Could not check this person's security keys.",
    'Bu kişinin güvenlik anahtarları kontrol edilemedi.',
  );
}

/// No Olm session with this contact can open the message yet; try again when a session appears (not final).
final class SessionPendingFailure extends Failure {
  const SessionPendingFailure();

  @override
  String get message => failureText(
    'Setting up encryption. Try again in a moment.',
    'Şifreleme hazırlanıyor. Biraz sonra tekrar dene.',
  );
}

/// The message failed its integrity check (MAC or authentication) or its session could not be opened; final, never retried.
final class UnreadableMessageFailure extends Failure {
  const UnreadableMessageFailure();

  @override
  String get message =>
      failureText('This message could not be opened.', 'Bu mesaj açılamadı.');
}

/// The session or message could not be saved on this phone; nothing was changed.
final class SessionStoreFailure extends Failure {
  const SessionStoreFailure();

  @override
  String get message => failureText(
    'Could not save the encryption keys on this phone.',
    'Şifreleme anahtarları bu telefona kaydedilemedi.',
  );
}

/// Words for any error a screen shows: a Failure's own message, never a raw
/// SDK error (a platform plugin's text must not reach the member).
String failureReason(Object error) => error is Failure
    ? error.message
    : failureText(
        'Something went wrong. Try again.',
        'Bir şeyler ters gitti. Tekrar dene.',
      );

sealed class Result<T> {
  const Result();
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;
}

final class Err<T> extends Result<T> {
  const Err(this.failure);

  final Failure failure;
}
