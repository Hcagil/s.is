import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../../auth/domain/member.dart';
import '../application/chat_controllers.dart';
import 'find_from_contacts_views.dart';

/// Opens Find people from your contacts; returns the member chosen with
/// Message, or null on back.
Future<Member?> showFindFromContactsPage(BuildContext context) => Navigator.of(
  context,
).push<Member>(MaterialPageRoute(builder: (_) => const FindFromContactsPage()));

class FindFromContactsPage extends ConsumerWidget {
  /// Creates the page.
  const FindFromContactsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final state = ref.watch(findFromContactsControllerProvider);
    final ctrl = ref.read(findFromContactsControllerProvider.notifier);
    return Scaffold(
      key: const ValueKey('find-from-contacts-page'),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.findPeopleTitle),
            Text(l.findPeopleSub, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      body: switch (state) {
        AsyncData(value: FindNeedsConsent()) => FindAskView(
          title: l.findDiscTitle,
          body: l.findDiscBody,
          primaryLabel: l.findContinue,
          onPrimary: ctrl.accept,
          onNotNow: () => Navigator.of(context).pop(),
        ),
        AsyncData(value: FindDenied()) => FindAskView(
          title: l.findAskTitle,
          body: l.findAskBody,
          primaryLabel: l.findAllow,
          onPrimary: ctrl.allow,
          onNotNow: () => Navigator.of(context).pop(),
        ),
        AsyncData(value: final FindResult r) => FindResultView(
          result: r,
          onMessage: (m) => Navigator.of(context).pop(m),
        ),
        AsyncError(:final error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(failureReason(error)),
          ),
        ),
        _ => const Center(child: SisLoadingLogo(size: 40)),
      },
    );
  }
}
