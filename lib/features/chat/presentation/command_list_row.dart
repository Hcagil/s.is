import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/staff_registry.dart';

/// A row displaying a bot command with its badge and description.
class CommandRow extends StatelessWidget {
  /// Creates a [CommandRow].
  const CommandRow({super.key, required this.command, required this.onTap});

  /// The bot command to display.
  final StaffCommand command;

  /// The callback to invoke when the row is tapped.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    final l = AppLocalizations.of(context);

    final meaning = command.help(Localizations.localeOf(context).languageCode);

    final badge = Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [brand.brand, brand.brandDeep]),
      ),
      child: const Text(
        '/',
        style: TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    );

    final line1 = Text.rich(
      TextSpan(
        text: command.name,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: brand.text,
        ),
        children: [
          if (command.takesEmail || command.takesTag) ...[
            const WidgetSpan(child: SizedBox(width: 6)),
            TextSpan(
              text: command.takesTag ? l.cmdArgTag : l.cmdArgEmail,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: brand.muted,
              ),
            ),
          ],
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    final line2 = Text(
      meaning,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 13, color: brand.muted),
    );

    return Semantics(
      button: true,
      excludeSemantics: true,
      label: l.cmdRowLabel(command.name, meaning),
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        highlightColor: brand.surfaceHigh,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 56),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                badge,
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [line1, line2],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
