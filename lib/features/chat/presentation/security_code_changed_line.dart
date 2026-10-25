import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';

class SecurityCodeChangedLine extends StatelessWidget {
  const SecurityCodeChangedLine({
    super.key,
    required this.name,
    required this.onTap,
    this.verifiedBefore = false,
  });

  final String name;
  final VoidCallback onTap;
  final bool verifiedBefore;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final color =
        SisBrand.of(context).onChat ??
        Theme.of(context).colorScheme.onSurfaceVariant;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const ValueKey('security-code-changed-line'),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 24),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.shield_outlined, size: 14, color: color),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      verifiedBefore
                          ? l.securityCodeChangedUnverified(name)
                          : l.securityCodeChanged(name),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: color),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
