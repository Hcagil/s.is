// Fakes for the file boundary (ChatFileRepository, DeviceFiles) and the
// auto-download boundary (AutoDownloadStore, NetworkProbe), written by QA from
// the interfaces only. They behave like the real ones where that is
// inconvenient: every answer is late (a held Completer the test releases, or a
// short latency), a send can fail retryably as the offline network does, a
// download reports progress before it lands, and a probe can be unknown or
// throw.
import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/autodownload/domain/auto_download_settings.dart';
import 'package:sis/features/chat/domain/file_attachment.dart';
import 'package:sis/features/chat/domain/file_repository.dart';
import 'package:sis/features/chat/domain/message.dart';

/// A picked file, as DeviceFiles.pick hands it over (already copied to [path]).
PickedFile picked(
  String id, {
  String name = 'Cabin booking.pdf',
  String mime = 'application/pdf',
  int size = 2516582,
}) => PickedFile(
  id: id,
  path: '/app/files/$id/$name',
  name: name,
  mime: mime,
  size: size,
);

/// A stored file message, as the server answers and Realtime echoes it.
Message fileMessage(
  String id, {
  String conversationId = 'c1',
  String senderId = 'u2',
  String name = 'Cabin booking.pdf',
  String mime = 'application/pdf',
  int size = 2516582,
  DateTime? createdAt,
}) => Message(
  id: id,
  conversationId: conversationId,
  senderId: senderId,
  body: '',
  createdAt: createdAt ?? DateTime.now(),
  attachmentPath: '$conversationId/$id/$name',
  file: AttachedFile(name: name, mime: mime, size: size),
);

/// One send asked of the server, waiting for the test's answer.
class FileSendAsk {
  FileSendAsk(this.conversationId, this.file, this.replyTo);
  final String conversationId;
  final PickedFile file;
  final String? replyTo;
  final answer = Completer<Result<Message>>();
}

/// One download asked of the server, waiting for the test's answer.
class FileDownloadAsk {
  FileDownloadAsk(
    this.attachmentPath,
    this.destPath,
    this.onProgress,
    this.expectedSize,
  );
  final String attachmentPath;
  final int? expectedSize;
  final String destPath;
  final void Function(double fraction)? onProgress;
  final answer = Completer<Result<void>>();
}

/// [ChatFileRepository] whose every answer is held until the test gives it.
class FileRepoFake implements ChatFileRepository {
  FileRepoFake({this.self = 'u1', this.devices});

  final String self;

  /// When set, a successful download writes the file here, as the real one
  /// leaves it at destPath.
  final DeviceFilesFake? devices;

  final sends = <FileSendAsk>[];
  final downloads = <FileDownloadAsk>[];

  @override
  Future<Result<Message>> send(
    String conversationId,
    PickedFile file, {
    String? replyTo,
  }) {
    final ask = FileSendAsk(conversationId, file, replyTo);
    sends.add(ask);
    return ask.answer.future;
  }

  /// Answers send [i] with the stored message the server would write.
  void sendOk(int i) {
    final a = sends[i];
    a.answer.complete(
      Ok(
        fileMessage(
          a.file.id,
          conversationId: a.conversationId,
          senderId: self,
          name: a.file.name,
          mime: a.file.mime,
          size: a.file.size,
        ),
      ),
    );
  }

  void sendFail(int i, Failure f) => sends[i].answer.complete(Err(f));

  @override
  Future<Result<void>> download(
    String attachmentPath,
    String destPath, {
    void Function(double fraction)? onProgress,
    int? expectedSize,
  }) {
    final ask = FileDownloadAsk(
      attachmentPath,
      destPath,
      onProgress,
      expectedSize,
    );
    downloads.add(ask);
    return ask.answer.future;
  }

  void progress(int i, double f) => downloads[i].onProgress?.call(f);

  void downloadOk(int i) {
    final a = downloads[i];
    devices?.written.add(a.destPath);
    a.answer.complete(const Ok(null));
  }

  void downloadFail(int i, Failure f) => downloads[i].answer.complete(Err(f));
}

/// [DeviceFiles] with a scripted chooser and opener, answering a little late.
class DeviceFilesFake implements DeviceFiles {
  DeviceFilesFake({
    this.pickResult = const FilePick(),
    this.opens = true,
    this.latency = const Duration(milliseconds: 2),
  });

  FilePick pickResult;

  /// What open answers: false when no app on the phone opens the file.
  bool opens;
  final Duration latency;

  /// Paths that hold a complete file.
  final written = <String>{};
  final opened = <String>[];
  int picks = 0;
  int clears = 0;

  String _path(String id, String name) => '/app/files/$id/$name';

  @override
  Future<FilePick> pick() async {
    picks++;
    await Future<void>.delayed(latency);
    return pickResult;
  }

  @override
  Future<String?> storedPath(String messageId, String name) async {
    await Future<void>.delayed(latency);
    final p = _path(messageId, name);
    return written.contains(p) ? p : null;
  }

  @override
  Future<String> pathFor(String messageId, String name) async {
    await Future<void>.delayed(latency);
    return _path(messageId, name);
  }

  @override
  Future<bool> open(String path) async {
    await Future<void>.delayed(latency);
    opened.add(path);
    return opens;
  }

  @override
  Future<void> clear() async {
    clears++;
    written.clear();
  }
}

/// [NetworkProbe] answering [kind] late, or throwing when [error] is set.
class ProbeFake implements NetworkProbe {
  ProbeFake(this.kind, {this.error = false});
  NetworkKind? kind;
  bool error;
  int asks = 0;

  @override
  Future<NetworkKind?> current() async {
    asks++;
    await Future<void>.delayed(const Duration(milliseconds: 2));
    if (error) throw StateError('connectivity channel failed');
    return kind;
  }
}

/// [AutoDownloadStore] keeping what was saved; [failSaves] makes saving throw.
class AutoDownloadStoreFake implements AutoDownloadStore {
  AutoDownloadStoreFake([this.stored = const AutoDownloadSettings()]);
  AutoDownloadSettings stored;
  bool failSaves = false;
  final saved = <AutoDownloadSettings>[];

  @override
  Future<AutoDownloadSettings> load() async => stored;

  @override
  Future<void> save(AutoDownloadSettings settings) async {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    if (failSaves) throw StateError('disk full');
    saved.add(settings);
    stored = settings;
  }
}
