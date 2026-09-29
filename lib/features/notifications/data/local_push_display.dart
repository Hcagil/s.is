import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/notification_inbox.dart';
import 'push_receipt_log.dart';

/// Shows pushes Telegram-style: one MessagingStyle notification per chat (a
/// line per unread message, newest last) under one silent group summary.
/// Runs in the app and in the background isolate a push wakes, so its state
/// lives in shared preferences, not in memory, and a burst of pushes is
/// coalesced (see [show]). Thin on purpose (ARCHITECTURE rule 4): the folding
/// is notification_inbox.dart.
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

  /// Minimum gap between two flushes.
  static const _interval = Duration(milliseconds: 600);

  /// Between two posts to the plugin: Android sheds an app's notifications
  /// past about 5 enqueues a second.
  static const _enqueueGap = Duration(milliseconds: 250);

  /// Shade idle time after which a flush may alert again.
  static const _quiet = Duration(seconds: 8);

  // Per isolate (the app and the background handler each have their own).
  static Future<void> _lock = Future.value();
  static int _stored = 0; // lines stored by this isolate
  static int _postedThrough = 0; // highest _stored a finished flush covers
  static DateTime? _lastFlushEnd;

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

  /// One more message for [conversationId], as the server worded it. False
  /// (nothing drawn or stored) when nobody owns the inbox on this phone.
  ///
  /// Pushes can wake this many times at once, so each call only STORES its
  /// line, then waits out [_interval] and posts the whole current state in
  /// one flush; a call whose line an earlier flush already covered posts
  /// nothing. Returns true once its line is inside a posted notification.
  static Future<bool> show({
    required String conversationId,
    required String title,
    required String body,
  }) async {
    final at = DateTime.now();
    final mine = await _locked<int?>(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      if (prefs.getString(_ownerKey) == null) return null;
      await _save(
        addToInbox(
          await _load(),
          conversationId: conversationId,
          title: title,
          body: body,
          at: at,
        ),
      );
      return ++_stored;
    });
    if (mine == null) return false;

    // Wait out the interval since the last flush.
    final last = _lastFlushEnd;
    if (last != null) {
      final wait = _interval - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }

    await _locked<void>(() async {
      if (_postedThrough >= mine) return;
      final upTo = _stored;
      await _flush();
      _postedThrough = upTo;
      _lastFlushEnd = DateTime.now();
    });
    return true;
  }

  /// The owner [show] is currently keeping the shade for, or null. Lets a
  /// caller decide a push is addressed to someone else before ever reaching
  /// [show].
  static Future<String?> currentOwner() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString(_ownerKey);
  }

  /// The member opened [conversationId]: its notification goes.
  static Future<void> clear(String conversationId) => _locked<void>(() async {
    final inbox = removeFromInbox(await _load(), conversationId);
    await _save(inbox);
    await _plugin.cancel(id: _idFor(conversationId));
    await _showSummary(inbox);
  });

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

  /// Every pass over the stored inbox in this isolate runs one at a time, so
  /// concurrent pushes never overwrite each other's line. A failing [f] must
  /// not break the chain.
  static Future<T> _locked<T>(Future<T> Function() f) {
    final run = _lock.then((_) => f());
    _lock = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Posts everything not yet shown: each chat with unread lines, then the
  /// summary, [_enqueueGap] apart. Runs inside [_locked]. Alerts (sound,
  /// heads-up) only when the shade has been quiet for [_quiet], and then only
  /// for the first chat; every other post is silent.
  static Future<void> _flush() async {
    final inbox = await _load();
    final dirty = dirtyChats(inbox);
    if (dirty.isEmpty) return;
    final last = _lastFlushEnd;
    final loud = last == null || DateTime.now().difference(last) > _quiet;
    for (var i = 0; i < dirty.length; i++) {
      if (i > 0) await Future<void>.delayed(_enqueueGap);
      await _showChat(dirty[i], alert: loud && i == 0);
    }
    await Future<void>.delayed(_enqueueGap);
    await _showSummary(inbox);
    await _save(markPosted(inbox, {for (final c in dirty) c.conversationId}));
  }

  /// The chat's notification: its whole current state (newest lines, oldest
  /// first), so a later post can never lose an earlier message.
  static Future<void> _showChat(InboxChat chat, {required bool alert}) =>
      _plugin.show(
        id: _idFor(chat.conversationId),
        title: chat.title,
        body: chat.lines.last.text,
        payload: chat.conversationId,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
            groupKey: _group,
            silent: !alert,
            onlyAlertOnce: !alert,
            number: chat.count,
            subText: chat.count > 1 ? '${chat.count} new messages' : null,
            when: chat.lines.last.at == 0 ? null : chat.lines.last.at,
            styleInformation: MessagingStyleInformation(
              const Person(name: 'You'),
              conversationTitle: chat.group ? chat.title : null,
              groupConversation: chat.group,
              messages: [
                for (final l in chat.lines)
                  Message(
                    l.text,
                    DateTime.fromMillisecondsSinceEpoch(l.at),
                    l.sender.isEmpty ? null : Person(name: l.sender),
                  ),
              ],
            ),
          ),
        ),
      );

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
          _channelId,
          _channelName,
          channelDescription: _channelDescription,
          groupKey: _group,
          setAsGroupSummary: true,
          silent: true,
          groupAlertBehavior: GroupAlertBehavior.children,
          styleInformation: InboxStyleInformation(
            [
              for (final c in inbox.reversed)
                '${c.title}: ${c.lines.last.text}',
            ],
            contentTitle: 'SIS',
            summaryText: inboxSummary(inbox),
          ),
        ),
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
    } catch (_) {
      // Unreadable (or an older format): start empty rather than fail a push.
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
