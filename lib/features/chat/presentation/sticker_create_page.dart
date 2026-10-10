import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';

/// Placeholder for making your own stickers; the next step replaces it.
class StickerCreatePage extends StatelessWidget {
  /// Creates the placeholder page.
  const StickerCreatePage({super.key});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final brand = SisBrand.of(context);
    return Scaffold(
      key: const ValueKey('sticker-create-page'),
      appBar: AppBar(title: Text(l.stickerCreateTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome_outlined, size: 48, color: brand.muted),
              const SizedBox(height: 16),
              Text(
                l.stickerCreateSoon,
                textAlign: TextAlign.center,
                style: TextStyle(color: brand.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
