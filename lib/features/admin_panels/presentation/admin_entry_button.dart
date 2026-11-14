import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../application/admin_entry_provider.dart';
import '../application/admin_panels_controller.dart';
import 'admin_panels_screen.dart';

/// Home top-bar icon into Admin Panels; shown only to the owner account.
/// Its number is the total of the tab numbers inside Admin Panels.
class AdminEntryButton extends ConsumerStatefulWidget {
  const AdminEntryButton({super.key});

  @override
  ConsumerState<AdminEntryButton> createState() => _AdminEntryButtonState();
}

class _AdminEntryButtonState extends ConsumerState<AdminEntryButton>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Background: clear the decrypted snapshot even when the panel is closed.
    if (state != AppLifecycleState.paused &&
        state != AppLifecycleState.hidden) {
      return;
    }
    if (!(ref.read(adminEntryProvider).value ?? false)) {
      return;
    }
    ref.read(adminPanelsProvider.notifier).lock();
  }

  @override
  Widget build(BuildContext context) {
    if (!(ref.watch(adminEntryProvider).value ?? false)) {
      return const SizedBox.shrink();
    }
    final total = ref.watch(
      adminPanelsProvider.select(
        (s) => s.newCounts.values.fold<int>(0, (a, b) => a + b),
      ),
    );
    const icon = Icon(Icons.dashboard_outlined);
    return IconButton(
      key: const ValueKey('home-admin'),
      tooltip: AppLocalizations.of(context).adminTitle,
      icon: total == 0 ? icon : Badge(label: Text('$total'), child: icon),
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const AdminPanelsScreen()),
      ),
    );
  }
}
