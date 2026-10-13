import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../chat/presentation/message_menu_card.dart';
import '../application/appearance_controller.dart';
import '../domain/appearance_settings.dart';
import '../domain/custom_theme.dart';
import 'appearance_labels.dart';

/// Opens the Rename / Duplicate / Delete card for [theme] and applies the
/// choice.
Future<void> openCustomThemeMenu(
  BuildContext context,
  WidgetRef ref,
  CustomTheme theme,
  Rect anchor,
) async {
  final l = AppLocalizations.of(context);
  final notifier = ref.read(appearanceProvider.notifier);
  final choice = await showMenuCard<String>(
    context,
    anchor: anchor,
    alignEnd: true,
    below: true,
    highlightAnchor: false,
    cardKey: const ValueKey('custom-theme-card'),
    actions: [
      MenuCardAction<String>(
        value: 'rename',
        keyId: 'theme-rename',
        rowKey: const ValueKey('theme-rename'),
        icon: Icons.edit_outlined,
        label: l.appearanceRename,
      ),
      MenuCardAction<String>(
        value: 'duplicate',
        keyId: 'theme-duplicate',
        rowKey: const ValueKey('theme-duplicate'),
        icon: Icons.copy_outlined,
        label: l.appearanceDuplicate,
      ),
      MenuCardAction<String>(
        value: 'delete',
        keyId: 'theme-delete',
        rowKey: const ValueKey('theme-delete'),
        icon: Icons.delete_outline_rounded,
        label: l.appearanceDelete,
        destructive: true,
      ),
    ],
  );
  if (choice == null || !context.mounted) return;

  switch (choice) {
    case 'rename':
      final newName = await showRenameThemeCard(context, anchor, theme.name);
      if (newName != null) await notifier.renameCustomTheme(theme.id, newName);
    case 'duplicate':
      await notifier.duplicateCustomTheme(
        theme.id,
        l.appearanceCopyName(theme.name),
      );
    case 'delete':
      await notifier.deleteCustomTheme(theme.id);
  }
}

/// Shows a card to rename a theme; returns the new name, or null when closed.
Future<String?> showRenameThemeCard(
  BuildContext context,
  Rect anchor,
  String current,
) {
  return showFloatingCard<String>(
    context,
    anchor: anchor,
    alignEnd: true,
    below: true,
    highlightAnchor: false,
    cardKey: const ValueKey('theme-rename-card'),
    child: _RenameForm(current: current),
  );
}

/// Makes a custom copy of the built-in theme [id] (same colours, mode
/// Automatic) and selects it.
Future<void> duplicateBuiltInTheme(
  WidgetRef ref,
  AppLocalizations l,
  Brightness brightness,
  AppThemeId id,
) async {
  final p = sisBrandFor(id, brightness);
  await ref
      .read(appearanceProvider.notifier)
      .createCustomTheme(
        name: l.appearanceCopyName(themeLabel(l, id)),
        mode: CustomThemeMode.automatic,
        accent: p.brand.toARGB32(),
        mine: p.brandDeep.toARGB32(),
        theirs: p.theirs.toARGB32(),
      );
}

class _RenameForm extends StatefulWidget {
  const _RenameForm({required this.current});

  final String current;

  @override
  State<_RenameForm> createState() => _RenameFormState();
}

class _RenameFormState extends State<_RenameForm> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.current,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) Navigator.of(context).pop(text);
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
              l.appearanceRenameTitle,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('theme-rename-field'),
              controller: _controller,
              autofocus: true,
              maxLength: 30,
              decoration: InputDecoration(hintText: l.appearanceThemeName),
              onSubmitted: (_) => _save(),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  key: const ValueKey('theme-rename-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l.appearanceCancel),
                ),
                TextButton(
                  key: const ValueKey('theme-rename-save'),
                  onPressed: _save,
                  child: Text(l.commonSave),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
