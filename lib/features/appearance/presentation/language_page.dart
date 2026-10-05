import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/controls.dart';
import '../../../l10n/app_localizations.dart';
import '../application/appearance_controller.dart';
import '../domain/appearance_settings.dart';
import 'appearance_labels.dart';

class LanguagePage extends ConsumerWidget {
  const LanguagePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = ref.watch(appearanceProvider);
    final l = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsLanguage)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            for (final v in AppLanguage.values)
              SisChoiceCard<AppLanguage>(
                key: ValueKey('language-${v.name}'),
                value: v,
                groupValue: look.language,
                onChanged: ref.read(appearanceProvider.notifier).setLanguage,
                title: languageLabel(l, v),
                subtitle: v == AppLanguage.system ? l.languageSystemHint : null,
              ),
          ],
        ),
      ),
    );
  }
}
