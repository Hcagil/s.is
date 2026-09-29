import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/alert_settings.dart';
import 'push_receipt_log.dart';

/// Deletes the alerting channels no chat and no default uses any more, and
/// the pre-0.26 single 'messages' channel (channels cannot be edited, so a
/// combination is a channel of its own, created when first drawn). Never
/// throws: this is housekeeping, and runs at app start and on every change
/// of a setting.
Future<void> pruneAlertChannels(AlertStore store) async {
  try {
    final android = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android == null) return;
    final used = usedAlertChannelIds(
      await store.loadDefaults(),
      await store.loadChats(),
    );
    for (final c
        in await android.getNotificationChannels() ??
            const <AndroidNotificationChannel>[]) {
      final ours = c.id.startsWith(alertChannelPrefix) || c.id == 'messages';
      if (ours && !used.contains(c.id)) {
        await android.deleteNotificationChannel(channelId: c.id);
      }
    }
  } catch (e) {
    await PushReceiptLog.add('error', error: e, label: 'pruneChannels');
  }
}
