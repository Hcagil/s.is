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
    this.subtitle,
    this.fullSubtitle = false,
    this.onTap,
    this.iconColor,
    this.showArrow = true,
  });

  final IconData icon;
  final String title;
  final String? value;
  final String? subtitle;

  /// When true the subtitle is not cut and uses bodyMedium.
  final bool fullSubtitle;
  final VoidCallback? onTap;
  final Color? iconColor;
  final bool showArrow;

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
                Icon(icon, color: iconColor ?? t.muted),
                const SizedBox(width: 16),
                Expanded(
                  child: subtitle == null
                      ? Text(title, style: style)
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: style),
                            Text(
                              subtitle!,
                              maxLines: fullSubtitle ? null : 2,
                              overflow: fullSubtitle
                                  ? TextOverflow.clip
                                  : TextOverflow.ellipsis,
                              style:
                                  (fullSubtitle
                                          ? Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                          : Theme.of(context)
                                                .textTheme
                                                .bodySmall)
                                      ?.copyWith(color: t.muted),
                            ),
                          ],
                        ),
                ),
                if (value != null)
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.sizeOf(context).width * 0.5,
                    ),
                    child: Text(
                      value!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: style?.copyWith(color: t.muted),
                    ),
                  ),
                if (showArrow) ...[
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, color: t.muted),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
