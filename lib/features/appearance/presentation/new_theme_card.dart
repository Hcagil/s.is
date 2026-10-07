import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/message_menu_card.dart';

/// Shows the card that asks for a new theme's name; returns the trimmed name,
/// or null when closed.
Future<String?> showNewThemeCard(BuildContext context, Rect anchor) {
  return showFloatingCard<String>(
    context,
    anchor: anchor,
    alignEnd: true,
    below: true,
    highlightAnchor: false,
    cardKey: const ValueKey('new-theme-card'),
    child: const _NewThemeForm(),
  );
}

class _NewThemeForm extends StatefulWidget {
  const _NewThemeForm();

  @override
  State<_NewThemeForm> createState() => _NewThemeFormState();
}

class _NewThemeFormState extends State<_NewThemeForm> {
  final TextEditingController _controller = TextEditingController();
  bool _empty = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// An empty name is refused: the card stays open and says why.
  void _create() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _empty = true);
      return;
    }
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SizedBox(
      width: 280,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.appearanceCreateTheme,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('new-theme-field'),
              controller: _controller,
              autofocus: true,
              maxLength: 30,
              decoration: InputDecoration(
                hintText: l.appearanceThemePlaceholder,
              ),
              onChanged: (_) {
                if (_empty) setState(() => _empty = false);
              },
              onSubmitted: (_) => _create(),
            ),
            if (_empty)
              Text(
                l.appearanceNameEmpty,
                key: const ValueKey('new-theme-empty'),
                style: TextStyle(
                  color: SisBrand.of(context).danger,
                  fontSize: 12,
                ),
              ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('new-theme-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l.appearanceCancel),
                ),
                TextButton(
                  key: const ValueKey('new-theme-create'),
                  onPressed: _create,
                  child: Text(l.appearanceCreate),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
