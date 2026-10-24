import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/settings_row.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/security_code_controller.dart';
import 'security_code_page.dart';

/// The Encryption row of a person's profile: opens their security code.
class EncryptionRow extends ConsumerWidget {
  const EncryptionRow({super.key, required this.userId, required this.name});

  final String userId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final state = ref.watch(securityCodeProvider(userId)).value;
    final verified = state is SecurityCodeReady && state.verified;
    final ready = state is SecurityCodeReady;

    return SisSettingsRow(
      key: const ValueKey('person-encryption'),
      icon: verified ? Icons.verified_user_rounded : Icons.lock_outline_rounded,
      iconColor: verified ? SisBrand.of(context).brand : null,
      title: l.encryptionRowTitle,
      subtitle: verified ? l.encryptionRowVerified : l.encryptionRowSubtitle,
      onTap: ready
          ? () => showSecurityCodePage(context, peerUserId: userId, name: name)
          : null,
    );
  }
}
