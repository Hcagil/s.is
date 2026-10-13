import 'voice.dart';

/// The maximum a file message may weigh (the server bucket enforces the same).
const int maxFileBytes = 50 * 1024 * 1024;

/// The file a stored message carries: its original name, MIME type and size in bytes.
final class AttachedFile {
  /// Creates a file attachment with the given name, MIME type and size.
  const AttachedFile({
    required this.name,
    required this.mime,
    required this.size,
    this.durationMs,
    this.thumbPath,
    this.waveform,
    this.transcript,
  });

  /// The file's original name.
  final String name;

  /// The file's MIME type.
  final String mime;

  /// The file's size in bytes.
  final int size;

  /// The length of a video in milliseconds, or null when this file is not a video.
  final int? durationMs;

  /// The path of the small jpeg picture of a video on this phone while it is still being sent, or null.
  final String? thumbPath;

  /// Voice messages: the stored waveform, see encodeWaveform.
  final String? waveform;

  /// Voice messages: the words, made on the sender's phone, or null.
  final String? transcript;

  /// Whether this is a voice message: an audio/mp4 file with a length.
  bool get isVoice => durationMs != null && mime == voiceMime;

  /// Whether this is a video: a file with a length that is not a voice message.
  bool get isVideo => durationMs != null && !isVoice;
}

/// A file the member picked, already copied into the app's own folder at [path];
/// [id] is the id of the message that will carry it (also the folder name).
final class PickedFile {
  /// Creates a picked file with the given properties.
  const PickedFile({
    required this.id,
    required this.path,
    required this.name,
    required this.mime,
    required this.size,
    this.durationMs,
    this.thumbPath,
    this.waveform,
    this.transcript,
  });

  /// The ID of the message that will carry this file.
  final String id;

  /// The path to the file in the app's own folder.
  final String path;

  /// The file's original name.
  final String name;

  /// The file's MIME type.
  final String mime;

  /// The file's size in bytes.
  final int size;

  /// The video's length in milliseconds, or null when this file is not a video.
  final int? durationMs;

  /// The path of the video's jpeg thumbnail on this phone, or null.
  final String? thumbPath;

  /// Voice messages: the stored waveform, see encodeWaveform.
  final String? waveform;

  /// Voice messages: the words, made on the sender's phone, or null.
  final String? transcript;

  /// Returns an attached file representation of this picked file.
  AttachedFile get attached => AttachedFile(
    name: name,
    mime: mime,
    size: size,
    durationMs: durationMs,
    thumbPath: thumbPath,
    waveform: waveform,
    transcript: transcript,
  );
}

/// What the file chooser returned: the usable files, and how many picked files
/// were refused for being over [maxFileBytes].
final class FilePick {
  /// Creates a file pick with the given properties.
  const FilePick({this.files = const [], this.tooBig = 0});

  /// The list of picked files that are within size limits.
  final List<PickedFile> files;

  /// The number of picked files that exceeded [maxFileBytes].
  final int tooBig;
}

/// Returns a human-readable file size label for the given number of bytes.
String fileSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).round()} KB';
  }
  if (bytes < 1024 * 1024 * 1024) {
    final v = bytes / (1024 * 1024);
    if (v >= 10) {
      return '${v.round()} MB';
    } else {
      return '${v.toStringAsFixed(1)} MB';
    }
  } else {
    final v = bytes / (1024 * 1024 * 1024);
    if (v >= 10) {
      return '${v.round()} GB';
    } else {
      return '${v.toStringAsFixed(1)} GB';
    }
  }
}

/// Returns the file type label for the given file name.
String fileTypeLabel(String name) {
  final lastDot = name.lastIndexOf('.');
  if (lastDot <= 0 || lastDot == name.length - 1) return 'FILE';
  final ext = name.substring(lastDot + 1);
  return ext.substring(0, ext.length > 5 ? 5 : ext.length).toUpperCase();
}

/// Returns the one-line preview of a file message in the chat list.
String filePreview(String name) => '\u{1F4CE} $name';

/// Unicode direction marks and zero-width characters (U+200B-U+200F,
/// U+202A-U+202E, U+2066-U+2069). They can disguise a file's real type
/// ("invoice, RLO mark, fdp.apk"), so they never stay in a name.
final _hiddenChars = RegExp('[\u200B-\u200F\u202A-\u202E\u2066-\u2069]');

/// Returns [name] without direction marks and zero-width characters.
String stripHiddenChars(String name) => name.replaceAll(_hiddenChars, '');

/// Returns a safe file name for use on the phone.
String safeFileName(String name) {
  final clean = stripHiddenChars(name)
      .replaceAll(RegExp(r'[\\/:*?"<>|\u0000-\u001f]'), '_');
  var trimmed = clean.trim();
  trimmed = trimmed.replaceFirst(RegExp(r'^\.+'), '');
  if (trimmed.isEmpty) return 'file';
  if (trimmed.length > 120) {
    return trimmed.substring(trimmed.length - 120);
  }
  return trimmed;
}

/// Returns whether the given file size exceeds [maxFileBytes].
bool isFileTooBig(int bytes) => bytes > maxFileBytes;
