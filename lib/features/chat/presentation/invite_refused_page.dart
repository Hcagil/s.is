import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';

class InviteRefusedPage extends StatelessWidget {
  const InviteRefusedPage({super.key, required this.problem});

  final InviteLinkProblem problem;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final (String pageTitle, String? headline, String body) = switch (problem) {
      InviteLinkProblem.invalid || InviteLinkProblem.expired => (
        l.inviteInvalidPageTitle,
        l.inviteInvalidTitle,
        l.inviteInvalidBody,
      ),
      InviteLinkProblem.closed => (
        l.composerGroupClosedNoName,
        null,
        l.inviteClosedBody,
      ),
      InviteLinkProblem.removed => (
        l.inviteRemovedTitle,
        null,
        l.inviteRemovedBody,
      ),
    };

    return Scaffold(
      key: const ValueKey('invite-refused-page'),
      appBar: AppBar(title: Text(pageTitle)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (headline != null)
                Text(
                  headline,
                  key: const ValueKey('invite-refused-title'),
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              const SizedBox(height: 8),
              Text(
                body,
                key: const ValueKey('invite-refused-body'),
                style: TextStyle(color: t.muted),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('invite-refused-ok'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l.securityCodeOk),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
