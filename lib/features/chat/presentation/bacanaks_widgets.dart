import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';

/// The round coins-stack avatar of the Bacanaks Ozel chat.
class BacanaksAvatar extends StatelessWidget {
  const BacanaksAvatar({super.key, this.radius = 18});

  final double radius;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: [brand.brand, brand.brandDeep]),
      ),
      child: const Icon(Icons.layers, size: 18, color: Colors.white),
    );
  }
}

/// The "/" suggestion row above the composer; a tap sends the command.
class PodiumSlashPanel extends StatelessWidget {
  const PodiumSlashPanel({
    super.key,
    required this.controller,
    required this.onPick,
  });

  final TextEditingController controller;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, v, _) {
        final t = v.text.trim().toLowerCase();
        if (!t.startsWith('/') || !'/podium'.startsWith(t)) {
          return const SizedBox.shrink();
        }
        return InkWell(
          onTap: onPick,
          child: Container(
            key: const ValueKey('podium-slash-panel'),
            margin: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: brand.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: brand.line),
            ),
            child: Row(
              children: [
                const BacanaksAvatar(),
                const SizedBox(width: 12),
                const Text('/podium', style: TextStyle(fontSize: 16)),
                Expanded(
                  child: Text(
                    AppLocalizations.of(context).podCmdDesc,
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 14, color: brand.muted),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Three calm dots while a /podium ask has no answer yet (gone after 2 minutes).
class PodiumWaiting extends ConsumerWidget {
  const PodiumWaiting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = SisBrand.of(context);
    final last = ref.watch(messagesProvider).value?.lastOrNull;
    if (last == null ||
        last.adminMsg != null ||
        last.body.trim().toLowerCase() != '/podium' ||
        DateTime.now().difference(last.createdAt) >=
            const Duration(minutes: 2)) {
      return const SizedBox.shrink();
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        key: const ValueKey('podium-waiting'),
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: brand.theirs,
          borderRadius: BorderRadius.circular(brand.bubbleRadius),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(
            3,
            (i) => Container(
              width: 6,
              height: 6,
              margin: EdgeInsets.only(right: i == 2 ? 0 : 4),
              decoration: BoxDecoration(
                color: brand.muted,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
