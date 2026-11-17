import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// copy-lead EN+TR pending
String adminQuestionFromLabel(String conv) => 'from $conv';

/// copy-lead EN+TR pending
String adminQuestionCountText(int n) => '$n to answer';

class AdminQuestionGroupHeader extends StatelessWidget {
  const AdminQuestionGroupHeader({
    super.key,
    required this.title,
    required this.count,
    required this.expanded,
    required this.onToggle,
    this.indent = 0,
  });

  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;
  final double indent;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);

    return Padding(
      padding: EdgeInsets.only(left: indent, top: 8, bottom: 8),
      child: InkWell(
        onTap: onToggle,
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              adminQuestionCountText(count),
              style: TextStyle(color: t.muted),
            ),
            const SizedBox(width: 8),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              color: t.muted,
            ),
          ],
        ),
      ),
    );
  }
}
