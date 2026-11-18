import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';

/// The line above the first unread message when a chat opens (no number).
class UnreadDivider extends StatelessWidget {
  const UnreadDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final b = SisBrand.of(context);
    final copper = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFFC58B68)
        : const Color(0xFF9A5F3D);
    return Padding(
      key: const ValueKey('unread-divider'),
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            Expanded(child: Container(height: 1, color: b.line)),
            const SizedBox(width: 12),
            Text(
              AppLocalizations.of(context).chatUnreadDivider,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: copper,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Container(height: 1, color: b.line)),
          ],
        ),
      ),
    );
  }
}
