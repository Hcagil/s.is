import 'package:flutter/material.dart';

import '../../../app/grey_option.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/domain/member.dart';
import '../application/chat_controllers.dart';
import 'person_avatar.dart';

/// A centred icon, title, body and two buttons: the first-use disclosure and
/// the contacts permission ask share this layout.
class FindAskView extends StatelessWidget {
  const FindAskView({
    super.key,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    required this.onNotNow,
  });

  final String title;
  final String body;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final VoidCallback onNotNow;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    final l = AppLocalizations.of(context);
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            Icon(Icons.contacts_outlined, size: 44, color: t.brand),
            const SizedBox(height: 24),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Text(
              body,
              style: TextStyle(color: t.muted, fontSize: 14, height: 1.5),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('find-primary'),
                onPressed: onPrimary,
                child: Text(primaryLabel),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              key: const ValueKey('find-not-now'),
              onPressed: onNotNow,
              child: Text(l.findNotNow),
            ),
          ],
        ),
      ),
    );
  }
}

/// The lookup result: contacts on SIS (Message) and not on SIS (Invite,
/// greyed: it arrives later).
class FindResultView extends StatelessWidget {
  const FindResultView({
    super.key,
    required this.result,
    required this.onMessage,
  });

  final FindResult result;
  final void Function(Member) onMessage;

  Widget _header(SisBrand t, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        color: t.muted,
        fontSize: 11.5,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.7,
      ),
    ),
  );

  Widget _row({
    required Key key,
    required Widget avatar,
    required String name,
    required String? sub,
    required SisBrand t,
    required Widget trailing,
  }) => Padding(
    key: key,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      children: [
        avatar,
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: const TextStyle(fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (sub != null)
                Text(sub, style: TextStyle(color: t.muted, fontSize: 13)),
            ],
          ),
        ),
        const SizedBox(width: 12),
        trailing,
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    return ListView(
      children: [
        if (result.limited)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              l.findLater,
              key: const ValueKey('find-limited'),
              style: TextStyle(color: t.muted),
            ),
          ),
        if (result.onSis.isEmpty && result.notOnSis.isEmpty && !result.limited)
          Padding(
            padding: const EdgeInsets.all(24),
            child: Center(child: Text(l.findEmpty)),
          ),
        if (result.onSis.isNotEmpty) _header(t, l.findOnSis),
        for (final c in result.onSis)
          _row(
            key: ValueKey('find-on-${c.member.userId}'),
            avatar: PersonAvatar(
              label: c.name,
              seed: c.member.userId,
              avatarPath: c.member.avatarPath,
            ),
            name: c.name,
            sub: c.member.tag == null ? null : '@${c.member.tag}',
            t: t,
            trailing: FilledButton(
              key: ValueKey('find-message-${c.member.userId}'),
              onPressed: () => onMessage(c.member),
              child: Text(l.findMessage),
            ),
          ),
        if (result.notOnSis.isNotEmpty) _header(t, l.findNotOnSis),
        for (var i = 0; i < result.notOnSis.length; i++)
          _row(
            key: ValueKey('find-off-$i'),
            avatar: PersonAvatar(
              label: result.notOnSis[i],
              seed: result.notOnSis[i],
            ),
            name: result.notOnSis[i],
            sub: l.findNotOnSisSub,
            t: t,
            trailing: GreyOption(
              name: 'f_inv',
              label: l.findInvite,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: t.brand,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  l.findInvite,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
