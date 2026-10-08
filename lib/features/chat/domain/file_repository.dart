import '../../../core/failure.dart';
import 'file_attachment.dart';
import 'message.dart';

/// The boundary for sending and downloading files. A repository never throws.
abstract interface class ChatFileRepository {
  /// Uploads [file] and stores the file message (id = file.id; a client-made id so a retry after a lost answer is harmless: if the object or the message already exists from an earlier attempt of the same send, that is success). Returns the stored message. DeniedFailure when the caller may not post there. When [file] has a thumbPath, that small jpeg is uploaded next to the video as `<path>.t` first. [onProgress] reports the upload from 0 to 1 (the video's bytes). A repository never throws.
  Future<Result<Message>> send(
    String conversationId,
    PickedFile file, {
    String? replyTo,
    void Function(double fraction)? onProgress,
  });

  /// Downloads the stored object [attachmentPath] to the phone file
  /// [destPath], reporting progress from 0 to 1 in [onProgress] when the size
  /// is known. Never leaves a half-written file at [destPath]. [expectedSize],
  /// when given, is the size the message promised: a different byte count
  /// deletes the download and fails.
  Future<Result<void>> download(
    String attachmentPath,
    String destPath, {
    void Function(double fraction)? onProgress,
    int? expectedSize,
  });
}

/// The boundary for accessing files on the device. A repository never throws.
abstract interface class DeviceFiles {
  /// Opens the system file chooser (several files allowed). Each usable file is copied into the app's own folder under this phone and described by a PickedFile; files over maxFileBytes are only counted in FilePick.tooBig. Cancelled or failed: an empty FilePick.
  Future<FilePick> pick();

  /// The path of the kept file of message [messageId] named [name], or null when it is not on this phone.
  Future<String?> storedPath(String messageId, String name);

  /// Where the file of message [messageId] named [name] is to be kept (its folder is created). Not a promise that a file exists there yet.
  Future<String> pathFor(String messageId, String name);

  /// Opens [path] with the phone's own app for that type. False when no app can open it or it is gone.
  Future<bool> open(String path);

  /// Deletes every kept file: called on sign-out.
  Future<void> clear();
}
