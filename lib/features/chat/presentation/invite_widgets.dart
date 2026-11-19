import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import 'person_avatar.dart';

class InviteGroupHeader extends StatelessWidget {
  const InviteGroupHeader({
    super.key,
    required this.title,
    required this.seed,
    required this.memberCount,
    this.avatarPath,
  });

  final String title;
  final String seed;
  final int memberCount;
  final String? avatarPath;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        PersonAvatar(
          label: title,
          seed: seed,
          radius: 48,
          avatarPath: avatarPath,
        ),
        const SizedBox(height: 12),
        Text(
          title,
          key: const ValueKey('invite-group-name'),
          textAlign: TextAlign.center,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          AppLocalizations.of(context).groupMemberCount(memberCount),
          key: const ValueKey('invite-group-count'),
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class InviteLinkBox extends StatelessWidget {
  const InviteLinkBox({super.key, required this.text, this.grey = false});

  final String text;
  final bool grey;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: BoxDecoration(
        color: brand.surfaceHigh,
        borderRadius: BorderRadius.circular(SisTokens.settingsRowRadius),
      ),
      child: Text(
        text,
        key: const ValueKey('invite-link-text'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyLarge
            ?.copyWith(color: grey ? brand.muted : null),
      ),
    );
  }
}

class InviteRedBox extends StatelessWidget {
  const InviteRedBox({
    super.key,
    required this.text,
    this.keyId = 'invite-red-box',
  });

  final String text;
  final String keyId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: ValueKey(keyId),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(SisTokens.settingsRowRadius),
      ),
      child: Text(text, style: TextStyle(color: scheme.onErrorContainer)),
    );
  }
}
