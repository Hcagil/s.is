import 'package:shared_preferences/shared_preferences.dart';

import '../domain/push.dart';

/// [NotificationExplainerStore] over shared_preferences. Thin on purpose
/// (ARCHITECTURE rule 4): a single flag, verified on a device.
final class SharedPrefsNotificationExplainerStore
    implements NotificationExplainerStore {
  const SharedPrefsNotificationExplainerStore();

  static const _key = 'notification_explainer_shown';

  @override
  Future<bool> wasShown() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_key) ?? false;
  }

  @override
  Future<void> markShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, true);
  }
}
