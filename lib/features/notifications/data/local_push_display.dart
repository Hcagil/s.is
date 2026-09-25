import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/notification_inbox.dart';

/// Shows pushes as ONE grouped SIS notification (Telegram-style): a child
/// notification per chat listing its newest lines, under a summary that
/// expands into them. Runs in the app and in the background isolate a push
/// wakes, so its state lives in shared preferences, not in memory. Thin on
/// purpose (ARCHITECTURE rule 4): the folding is notification_inbox.dart.
final class LocalPushDisplay {
  LocalPushDisplay._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _group = 'sis.messages';
  static const _prefsKey = 'sis.push_inbox';
  static const _ownerKey = 'sis.push_inbox_owner';
  static const _summaryId = 0;
  static const _channelId = 'messages';
  static const _channelName = 'Messages';
  static const _channelDescription = 'New messages';

  /// Must run before [show] in each isolate. [onTap] receives the tapped
  /// chat's conversation id (the payload), when the app is running.
  static Future<void> init({void Function(String conversationId)? onTap}) =>
      _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings(
            '@drawable/ic_launcher_monochrome',
          ),
        ),
        onDidReceiveNotificationResponse: onTap == null
            ? null
            : (r) {
                final id = r.payload;
                if (id != null && id.isNotEmpty) onTap(id);
              },
      );

  /// The chat whose notification launched the app, or null.
  static Future<String?> launchConversation() async {
    final d = await _plugin.getNotificationAppLaunchDetails();
    final id = d?.notificationResponse?.payload;
    return d?.didNotificationLaunchApp == true && id != null && id.isNotEmpty
        ? id
        : null;
  }

  /// One more message for [conversationId], as the server worded it.
  static Future<void> show({
    required String conversationId,
    required String title,
    required String body,
  }) async {
    final inbox = addToInbox(
      await _load(),
      conversationId: conversationId,
      title: title,
      body: body,
    );
    await _save(inbox);
    final chat = inbox.last;
    await _plugin.show(
      id: _idFor(conversationId),
      title: chat.title,
      body: chat.lines.last,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          importance: Importance.high,
          priority: Priority.high,
          groupKey: _group,
          styleInformation: InboxStyleInformation(
            chat.lines,
            contentTitle: chat.title,
            summaryText: chat.count > 1 ? '${chat.count} new messages' : null,
          ),
        ),
      ),
      payload: conversationId,
    );
    await _showSummary(inbox);
  }

  /// The member opened [conversationId]: its notification goes.
  static Future<void> clear(String conversationId) async {
    final inbox = removeFromInbox(await _load(), conversationId);
    await _save(inbox);
    await _plugin.cancel(id: _idFor(conversationId));
    await _showSummary(inbox);
  }

  /// Sign-out: nothing of the last account stays in the shade.
  static Future<void> clearAll() async {
    await _save(const []);
    await _plugin.cancelAll();
  }

  /// The signed-in member is now [userId], or nobody (about to sign in, just
  /// signed out, or handed to someone else on the same phone). A no-op when
  /// nothing changed (the common case: this runs on every rebuild of the
  /// provider that watches who is signed in, not only on an actual change).
  /// On an actual change: drops whatever was stored for the previous member
  /// and empties the shade, then remembers the new owner, so a stale inbox
  /// can never be read as -- or merged into -- someone else's.
  static Future<void> forUser(String? userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final previousOwner = prefs.getString(_ownerKey);
    if (previousOwner == userId) return;
    await prefs.remove(_keyFor(previousOwner));
    await _plugin.cancelAll();
    if (userId == null) {
      await prefs.remove(_ownerKey);
    } else {
      await prefs.setString(_ownerKey, userId);
    }
  }

  static String _keyFor(String? owner) =>
      owner == null ? _prefsKey : '$_prefsKey.$owner';

  static Future<void> _showSummary(List<InboxChat> inbox) async {
    if (inbox.isEmpty) {
      await _plugin.cancel(id: _summaryId);
      return;
    }
    await _plugin.show(
      id: _summaryId,
      title: 'SIS',
      body: inboxSummary(inbox),
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          groupKey: _group,
          setAsGroupSummary: true,
          styleInformation: InboxStyleInformation(
            [for (final c in inbox.reversed) '${c.title}: ${c.lines.last}'],
            contentTitle: 'SIS',
            summaryText: inboxSummary(inbox),
          ),
        ),
      ),
      payload: inbox.last.conversationId,
    );
  }

  /// Stable across app versions (String.hashCode is not promised to be), and
  /// never the summary's id: FNV-1a over the id, kept positive and non-zero.
  static int _idFor(String conversationId) {
    var h = 0x811c9dc5;
    for (final unit in conversationId.codeUnits) {
      h = ((h ^ unit) * 0x01000193) & 0x7fffffff;
    }
    return h == _summaryId ? 1 : h;
  }

  static Future<List<InboxChat>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    // What the background isolate wrote must be seen here.
    await prefs.reload();
    final raw = prefs.getString(_keyFor(prefs.getString(_ownerKey)));
    if (raw == null) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          InboxChat.fromJson(e as Map<String, Object?>),
      ];
    } on FormatException {
      return const [];
    }
  }

  static Future<void> _save(List<InboxChat> inbox) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyFor(prefs.getString(_ownerKey)),
      jsonEncode([for (final c in inbox) c.toJson()]),
    );
  }
}
