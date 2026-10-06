import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/notification_inbox.dart';
import 'alert_channels.dart';
import 'push_receipt_log.dart';
import 'shared_prefs_alert_store.dart';

/// The Dart side of the notification shade. On Android InstantPush.kt draws
/// every chat notification (one MessagingStyle per chat under one silent
/// group summary, with the unlock-protected buttons) and keeps the inbox in
/// shared preferences; this class only removes what the member has dealt
/// with (clear, clearAll, forUser), redraws the group summary after a clear,
/// reports whether notifications are allowed and prunes unused channels.
/// Thin on purpose (ARCHITECTURE rule 4): the folding is
/// notification_inbox.dart.
final class LocalPushDisplay {
  LocalPushDisplay._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static const _group = 'sis.messages';
  static const _prefsKey = 'sis.push_inbox';
  static const _ownerKey = 'sis.push_inbox_owner';
  static const _summaryId = 0;
  static const _summaryChannelId = 'summary';
  static const _summaryChannelName = 'Summary';
  static const _channelDescription = 'New messages';
  static const _alerts = SharedPrefsAlertStore();

  /// iOS only: AppDelegate.swift removes a chat's delivered pushes by thread
  /// id.
  static const _iosChannel = MethodChannel('sis/notifications');

  // Per isolate (the app and the background handler each have their own).
  static Future<void> _lock = Future.value();

  /// Must run before [notificationsEnabled] and the taps in each isolate. [onTap] receives the tapped
  /// chat's conversation id (the payload), when the app is running.
  static Future<void> init({void Function(String conversationId)? onTap}) =>
      _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings(
            '@drawable/ic_launcher_monochrome',
          ),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
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

  /// The owner the shade is currently kept for, or null. Lets a caller
  /// decide a push is addressed to someone else.
  static Future<String?> currentOwner() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString(_ownerKey);
  }

  /// The member opened [conversationId]: its notification goes. On an iPhone
  /// this also removes the chat's delivered pushes (thread id = the
  /// conversation), which the plugin cannot see.
  static Future<void> clear(String conversationId) => _locked<void>(() async {
    final inbox = removeFromInbox(await _load(), conversationId);
    await _save(inbox);
    await _plugin.cancel(id: _idFor(conversationId));
    await _showSummary(inbox);
    await _clearDelivered(conversationId);
  });

  /// iOS only: the system, not this plugin, drew the chat's pushes, so they
  /// are removed by thread id through AppDelegate.swift. Never throws.
  static Future<void> _clearDelivered(String conversationId) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _iosChannel.invokeMethod<void>('clearThread', conversationId);
    } on PlatformException {
      // Nothing to remove, or the system refused: the chat is open anyway.
    } on MissingPluginException {
      // No native side (a test host).
    }
  }

  /// Sign-out: nothing of the last account stays in the shade.
  static Future<void> clearAll() => _locked<void>(() async {
    await _save(const []);
    await _plugin.cancelAll();
  });

  /// The signed-in member is now [userId], or nobody (about to sign in, just
  /// signed out, or handed to someone else on the same phone). A no-op when
  /// nothing changed (the common case: this runs on every rebuild of the
  /// provider that watches who is signed in, not only on an actual change).
  /// On an actual change: drops whatever was stored for the previous member
  /// and empties the shade, then remembers the new owner, so a stale inbox
  /// can never be read as -- or merged into -- someone else's. Nobody again
  /// is not a no-op: a push delivered late, after the session ended, must
  /// not wait in the shade until the next member signs in.
  static Future<void> forUser(String? userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final previousOwner = prefs.getString(_ownerKey);
    if (previousOwner == userId && userId != null) return;
    // Receipts are uploaded as whoever is signed in: one member's must never
    // go up under the next member's account.
    await PushReceiptLog.clear();
    await prefs.remove(_keyFor(previousOwner));
    // The owner is stored BEFORE the shade is cleared: cancelAll can throw
    // (in release, R8 broke its Gson use), and the owner was then never
    // written, so every push was dropped as no_owner.
    if (userId == null) {
      await prefs.remove(_ownerKey);
    } else {
      await prefs.setString(_ownerKey, userId);
    }
    try {
      await _plugin.cancelAll();
    } catch (e) {
      await PushReceiptLog.add('error', error: e, label: 'forUser cancelAll');
    }
  }

  /// Whether Android lets SIS draw notifications at all (the Android 13+
  /// permission, or switched off in settings). Anything else counts as yes.
  static Future<bool> notificationsEnabled() async =>
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.areNotificationsEnabled() ??
      true;

  static String _keyFor(String? owner) =>
      owner == null ? _prefsKey : '$_prefsKey.$owner';

  /// Deletes the alerting channels no chat and no default uses any more, and
  /// the pre-0.26 single 'messages' channel (channels cannot be edited, so a
  /// combination is a channel of its own, created when first drawn). Never
  /// throws: this is housekeeping, and runs at app start and on every change
  /// of a setting.
  static Future<void> pruneChannels() => pruneAlertChannels(_alerts);

  /// Every pass over the stored inbox in this isolate runs one at a time, so
  /// concurrent pushes never overwrite each other's line. A failing [f] must
  /// not break the chain.
  static Future<T> _locked<T>(Future<T> Function() f) {
    final run = _lock.then((_) => f());
    _lock = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// The silent group summary; no payload, so tapping it just opens the app
  /// on the chat list. Gone when nothing is waiting.
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
          _summaryChannelId,
          _summaryChannelName,
          channelDescription: _channelDescription,
          importance: Importance.low,
          playSound: false,
          enableVibration: false,
          groupKey: _group,
          setAsGroupSummary: true,
          silent: true,
          groupAlertBehavior: GroupAlertBehavior.children,
          styleInformation: InboxStyleInformation(
            [
              for (final c in inbox.reversed)
                c.group && c.lines.last.sender.isNotEmpty
                    ? '${c.title}: ${c.lines.last.sender}: ${c.lines.last.text}'
                    : '${c.title}: ${c.lines.last.text}',
            ],
            contentTitle: 'SIS',
            summaryText: inboxSummary(inbox),
          ),
        ),
        iOS: DarwinNotificationDetails(presentSound: false),
      ),
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

  static Future<List<InboxChat>> _load({String? owner}) async {
    final prefs = await SharedPreferences.getInstance();
    // What the background isolate wrote must be seen here.
    await prefs.reload();
    final raw = prefs.getString(_keyFor(owner ?? prefs.getString(_ownerKey)));
    if (raw == null) return const [];
    try {
      return [
        for (final e in jsonDecode(raw) as List)
          InboxChat.fromJson(e as Map<String, Object?>),
      ];
    } catch (_) {
      // Unreadable (or an older format): start empty rather than fail a push.
      return const [];
    }
  }

  static Future<void> _save(List<InboxChat> inbox, {String? owner}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _keyFor(owner ?? prefs.getString(_ownerKey)),
      jsonEncode([for (final c in inbox) c.toJson()]),
    );
  }
}
