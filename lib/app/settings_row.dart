import 'package:flutter/material.dart';

import 'theme.dart';

/// The one settings row: icon, name, optional value, arrow. Tighter padding
/// than a ListTile, same text size.
class SisSettingsRow extends StatelessWidget {
  const SisSettingsRow({
    super.key,
    required this.icon,
    required this.title,
    this.value,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    final style = Theme.of(context).textTheme.bodyLarge;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(SisTokens.settingsRowRadius),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: SisTokens.settingsRowPadding,
            child: Row(
              children: [
                Icon(icon, color: t.muted),
                const SizedBox(width: 16),
                Expanded(child: Text(title, style: style)),
                if (value != null)
                  Text(value!, style: style?.copyWith(color: t.muted)),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, color: t.muted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
