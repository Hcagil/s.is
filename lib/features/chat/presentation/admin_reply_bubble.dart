import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/message.dart';

/// The words of an admin chat reply in the app's language, from its machine-readable form; null for a key this build does not know (the caller shows the English body).
String? adminReplyText(AppLocalizations l, Map<String, dynamic> m) {
  final e = m['e'] as String? ?? '';
  final r = switch (m['r']) {
    'timeout' => l.adminReasonTimeout,
    'rejected' => l.adminReasonRejected,
    'dispatch' => l.adminReasonDispatch,
    final String other => other,
    _ => '',
  };
  final text = switch (m['k']) {
    'unk' => l.adminUnk,
    'noem' => l.adminNoem,
    'bad' => l.adminBad,
    'iosOk' => l.adminIosOk(e),
    'p1' => l.adminP1,
    'p2' => l.adminP2,
    'p3' => l.adminP3,
    'fail' => l.adminFail(e, r),
    'andOk' => l.adminAndOk(e),
    'rmOk' => l.adminRmOk(e),
    'canOk' => l.adminCanOk,
    'nolist' => l.adminNoList(e),
    'r1' => l.adminR1(e),
    'r2' => l.adminR2,
    'r3' => l.adminR3,
    'failRm' => l.adminFailRm(e, r),
    'rate' => l.adminRate,
    'keep' => l.adminKeep,
    'err' => l.adminErr,
    'nolink' => l.adminNoLink,
    'podFail' => l.podFail,
    'podOff' => l.podOff,
    'podUnk' => l.podUnk,
    'podRate' => l.podRate,
    'podSwOn' => l.podSwOn,
    'podSwOff' => l.podSwOff,
    _ => null,
  };
  if (text == null || m['help'] != true) return text;
  return '$text\n\n${l.adminHelpHeader}\n'
      '/addiostester ayla@mail.test - ${l.adminHelpIos}\n'
      '/addandroidtester can@mail.test - ${l.adminHelpAnd}\n'
      '/removetester deniz@mail.test - ${l.adminHelpRm}\n'
      '/listtesters - ${l.adminHelpList}';
}

/// The one-line chat-list preview of an admin reply in the reader's language.
String adminPreviewLine(AppLocalizations l, Map<String, dynamic> m) =>
    switch (m['k']) {
      'list' => l.adminListHeader(m['n'] as int? ?? 0),
      'fwd' => l.adminFwdTitle,
      'conf' => l.adminConfTitle,
      'pod' || 'podPrev' => l.podTitle,
      _ => (adminReplyText(l, m) ?? '').split('\n').first,
    };

List<String> _emails(Object? v) => [
  for (final x in (v as List?) ?? const []) '$x',
];

/// One reply of the admin account: plain text, the tester list, the forwardable Android invite, or the remove confirmation card.
class AdminReplyBubble extends ConsumerStatefulWidget {
  const AdminReplyBubble({super.key, required this.message});

  final Message message;

  @override
  ConsumerState<AdminReplyBubble> createState() => _AdminReplyBubbleState();
}

class _AdminReplyBubbleState extends ConsumerState<AdminReplyBubble> {
  bool _busy = false;

  Future<void> _answer(bool yes) async {
    setState(() => _busy = true);
    final res = await ref.read(adminAnswerProvider)(widget.message.id, yes);
    if (!mounted) return;
    setState(() => _busy = false);
    if (res case Err(:final failure)) {
      showSisNotice(context, failure.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final brand = SisBrand.of(context);
    final m = widget.message.adminMsg!;
    final muted = Theme.of(context).textTheme.bodySmall;
    Widget content;
    switch (m['k']) {
      case 'list':
        final ios = _emails(m['ios']);
        final and = _emails(m['and']);
        final oth = _emails(m['oth']);
        Widget group(String title, List<String> mails) => Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(mails.join('\n')),
            ],
          ),
        );
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.adminListHeader(m['n'] as int? ?? 0),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            if (ios.isNotEmpty) group(l.adminListIos(ios.length), ios),
            if (and.isNotEmpty) group(l.adminListAnd(and.length), and),
            if (oth.isNotEmpty) group(l.adminListOther(oth.length), oth),
          ],
        );
      case 'fwd':
        final text = l.adminFwdBody(
          m['e'] as String? ?? '',
          m['l'] as String? ?? '',
        );
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.adminFwdTitle,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(text),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    if (context.mounted) showSisNotice(context, l.adminCopied);
                  },
                  child: Text(l.adminCopy),
                ),
                TextButton(
                  onPressed: () => ref.read(textSharerProvider).share(text),
                  child: Text(l.adminShare),
                ),
              ],
            ),
          ],
        );
      case 'conf':
        final st = m['st'] as String?;
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.adminConfTitle,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(l.adminConfBody(m['e'] as String? ?? '')),
            const SizedBox(height: 8),
            if (st == null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _answer(false),
                    child: Text(l.adminConfNo),
                  ),
                  TextButton(
                    onPressed: _busy ? null : () => _answer(true),
                    child: Text(l.adminConfYes),
                  ),
                ],
              )
            else
              Text(
                st == 'done' ? l.adminConfDone : l.adminConfCancelled,
                style: muted,
              ),
          ],
        );
      case 'pod' || 'podPrev':
        final at = DateTime.tryParse('${m['at']}')?.toLocal();
        final day = DateTime.tryParse('${m['day']}');
        final locale = Localizations.localeOf(context).toString();
        content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              m['k'] == 'pod'
                  ? l.podTitle
                  : l.podPrevTitle(
                      day == null
                          ? ''
                          : DateFormat('d MMM', locale).format(day),
                    ),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: brand.muted,
              ),
            ),
            Text(
              '${m['amt']}',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: Theme.of(context).colorScheme.onSurface,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 4),
            Text(
              l.podFetched(at == null ? '' : DateFormat('HH:mm').format(at)),
              style: TextStyle(fontSize: 12, color: brand.muted),
            ),
            const SizedBox(height: 4),
          ],
        );
      case 'podFail' || 'podOff':
        content = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 16, color: brand.danger),
            const SizedBox(width: 8),
            Flexible(child: Text(adminReplyText(l, m) ?? '')),
          ],
        );
      default:
        content = Text(adminReplyText(l, m) ?? widget.message.body);
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: ValueKey('message-${widget.message.id}'),
        constraints: const BoxConstraints(maxWidth: 320),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: brand.theirs,
          borderRadius: BorderRadius.circular(brand.bubbleRadius),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(alignment: Alignment.centerLeft, child: content),
            Text(clockTime(widget.message.createdAt), style: muted),
          ],
        ),
      ),
    );
  }
}
