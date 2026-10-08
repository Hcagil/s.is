import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../l10n/app_localizations.dart';
import '../../autodownload/application/auto_download_controller.dart';
import '../../autodownload/domain/auto_download_settings.dart';
import '../application/chat_controllers.dart';
import '../domain/file_attachment.dart';
import '../domain/message.dart';

/// A file message: type tile, name and size; a received file not yet on this
/// phone shows a download ring.
class FileCard extends ConsumerWidget {
  const FileCard({
    super.key,
    required this.message,
    required this.ink,
    required this.accent,
    required this.time,
  });

  final Message message;
  final Color ink;
  final Color accent;
  final Widget time;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final file = message.file;
    if (file == null) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final stored = ref.watch(
      storedFileProvider((id: message.id, name: file.name)),
    );
    final progress = ref.watch(
      fileDownloadsProvider.select((s) => s[message.id]),
    );
    final autoOk =
        ref.watch(autoDownloadNowProvider(MediaKind.documents)).value ?? false;
    final path = stored.value;
    final needsDownload =
        stored is AsyncData<String?> &&
        path == null &&
        message.attachmentPath != null &&
        !message.sending;

    if (needsDownload && autoOk && progress == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(fileDownloadsProvider.notifier).auto(message);
      });
    }

    final downloading = progress != null;
    final ring = downloading || needsDownload;
    final type = fileTypeLabel(file.name);

    final leading = SizedBox(
      key: ValueKey(
        ring ? 'file-ring-${message.id}' : 'file-tile-${message.id}',
      ),
      width: 44,
      height: 44,
      child: ring
          ? Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: SisProgressRing(
                    value: downloading
                        ? (progress == 0 ? null : progress)
                        : 0.75,
                    color: accent,
                  ),
                ),
                Icon(Icons.arrow_downward_rounded, size: 20, color: accent),
              ],
            )
          : Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                type.length > 3 ? type.substring(0, 3) : type,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: accent,
                ),
              ),
            ),
    );

    final size = fileSizeLabel(file.size);
    final sub = Text(
      downloading
          ? '$size · ${(progress * 100).round()}%'
          : needsDownload
          ? l.fileTapToDownload(size)
          : '$size · $type',
      style: TextStyle(fontSize: 12, color: ink.withValues(alpha: 0.7)),
    );

    return SizedBox(
      key: ValueKey('file-${message.id}'),
      width: 240,
      child: InkWell(
        onTap: message.sending
            ? null
            : () async {
                if (path != null) {
                  final ok = await ref.read(deviceFilesProvider).open(path);
                  if (!ok && context.mounted) {
                    showSisNotice(context, l.fileCannotOpen, isError: true);
                  }
                } else if (!downloading && needsDownload) {
                  final failure = await ref
                      .read(fileDownloadsProvider.notifier)
                      .start(message);
                  if (failure != null && context.mounted) {
                    showSisNotice(context, failure.message, isError: true);
                  }
                }
              },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                leading,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        file.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: ink,
                        ),
                      ),
                      sub,
                    ],
                  ),
                ),
              ],
            ),
            Align(alignment: Alignment.centerRight, child: time),
          ],
        ),
      ),
    );
  }
}
