import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, visibleForTesting;
import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/alert_settings.dart';
import '../domain/notification_inbox.dart';
import 'alert_channels.dart';
import 'notification_avatars.dart';
import 'push_receipt_log.dart';
import 'shared_prefs_alert_store.dart';

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
  static const _summaryChannelId = 'summary';
  static const _summaryChannelName = 'Summary';
  static const _channelDescription = 'New messages';
  static const _alerts = SharedPrefsAlertStore();

  /// iOS only: AppDelegate.swift removes a chat's delivered pushes by thread
  /// id.
  static const _iosChannel = MethodChannel('sis/notifications');

  /// Between two posts to the plugin: Android sheds an app's notifications
  /// past about 5 enqueues a second; 300 ms keeps it under 4. Only waited out
  /// when a post follows another this closely (see [_pace]); a push on an idle
  /// phone posts at once.
  static const _enqueueGap = Duration(milliseconds: 300);

  /// Shade idle time after which a flush may alert again.
  static const _quiet = Duration(seconds: 8);

  // Per isolate (the app and the background handler each have their own).
  static Future<void> _lock = Future.value();
  static int _stored = 0; // lines stored by this isolate
  static int _postedThrough = 0; // highest _stored a finished flush covers
  static DateTime? _lastFlushEnd;
  static DateTime? _lastPostAt; // when this isolate last posted to the plugin

  /// Conversations Android already alerted for, until a flush posts them
  /// (per isolate).
  static final Set<String> _nativeAlerted = {};

  /// A fresh isolate, for tests.
  @visibleForTesting
  static void resetForTest() {
    _lock = Future.value();
    _stored = 0;
    _postedThrough = 0;
    _lastFlushEnd = null;
    _lastPostAt = null;
    _nativeAlerted.clear();
  }

  /// Must run before [show] in each isolate. [onTap] receives the tapped
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

  /// One more message for [conversationId], as the server worded it. False
  /// (nothing drawn or stored) when nobody owns the inbox on this phone.
  ///
  /// Pushes can wake this more than once at a time, so each call only STORES
  /// its line, then posts the whole current state in one flush (posts are
  /// paced by [_pace], so a backlog never trips Android's enqueue limit); a
  /// call whose line an earlier flush already covered posts nothing. Returns
  /// true once its line is inside a posted notification, false when nothing
  /// was posted for it.
  ///
  /// [sender] and [chat] are the server's separate fields for a group message.
  ///
  /// [alreadyAlerted]: Android already drew this push itself and alerted
  /// (InstantPush.kt); this post replaces that notification in place (same
  /// id) without sound or heads-up again.
  static Future<bool> show({
    required String conversationId,
    required String title,
    required String body,
    String? sender,
    String? chat,
    bool alreadyAlerted = false,
  }) async {
    final at = DateTime.now();
    String? lineOwner; // who the line is stored for
    final mine = await _locked<int?>(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      lineOwner = prefs.getString(_ownerKey);
      if (lineOwner == null) return null;
      if (alreadyAlerted) _nativeAlerted.add(conversationId);
      await _save(
        addToInbox(
          await _load(),
          conversationId: conversationId,
          title: title,
          body: body,
          at: at,
          sender: sender,
          chat: chat,
        ),
      );
      return ++_stored;
    });
    if (mine == null) return false;

    var posted = false;
    await _locked<void>(() async {
      // A line stored for one member is never reported posted because of a
      // flush that ran for another: after an owner change it stays unposted.
      if (await currentOwner() != lineOwner) return;
      if (_postedThrough >= mine) {
        posted = true; // an earlier flush already covered this line
        return;
      }
      final upTo = _stored;
      // False when the flush stopped early (the owner changed mid-way): the
      // line is then not in any posted notification and stays pending.
      if (!await _flush(lineOwner!)) return;
      _postedThrough = upTo;
      _lastFlushEnd = DateTime.now();
      posted = true;
    });
    return posted;
  }

  /// The owner [show] is currently keeping the shade for, or null. Lets a
  /// caller decide a push is addressed to someone else before ever reaching
  /// [show].
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

  /// Posts everything not yet shown: each chat with unread lines, then the
  /// summary, [_enqueueGap] apart. Runs inside [_locked]. Alerts (sound,
  /// heads-up) only when the shade has been quiet for [_quiet], and then only
  /// for the first chat Android had not already alerted for; every other
  /// post is silent.
  ///
  /// The member can sign out or switch in the app's isolate while a flush is
  /// posting: the owner is noted at load and re-read (fresh from disk) before
  /// every post and before the save, which goes to that owner's key only.
  ///
  /// Returns false when it stopped early because the owner changed, true
  /// otherwise (also when there was nothing to post). [expected] is the owner
  /// the line being posted was stored for; any other owner stops it (false).
  static Future<bool> _flush(String expected) async {
    final owner = await currentOwner();
    if (owner == null || owner != expected) return false;
    final inbox = await _load(owner: owner);
    final dirty = dirtyChats(inbox);
    if (dirty.isEmpty) return true;
    final last = _lastFlushEnd;
    final loud = last == null || DateTime.now().difference(last) > _quiet;
    final alertIndex = dirty.indexWhere(
      (c) => !_nativeAlerted.contains(c.conversationId),
    );
    final defaults = await _alerts.loadDefaults();
    final chats = await _alerts.loadChats();
    final pictures = await NotificationAvatars.forChats(owner, [
      for (final c in dirty) c.conversationId,
    ]);
    for (var i = 0; i < dirty.length; i++) {
      await _pace();
      if (!await _still(owner)) return false;
      await _showChat(
        dirty[i],
        alert: loud && i == alertIndex,
        picture: pictures[dirty[i].conversationId],
        effective: resolveAlert(
          defaults,
          chats[dirty[i].conversationId] ?? const ChatAlert(),
        ),
      );
    }
    await _pace();
    if (!await _still(owner)) return false;
    await _showSummary(inbox);
    if (!await _still(owner)) return false;
    await _save(
      markPosted(inbox, {for (final c in dirty) c.conversationId}),
      owner: owner,
    );
    _nativeAlerted.removeAll([for (final c in dirty) c.conversationId]);
    return true;
  }

  /// Waits only as long as it takes to leave [_enqueueGap] since this
  /// isolate's last post, then counts as a post itself.
  static Future<void> _pace() async {
    final last = _lastPostAt;
    if (last != null) {
      final wait = _enqueueGap - DateTime.now().difference(last);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    _lastPostAt = DateTime.now();
  }

  static Future<bool> _still(String owner) async =>
      await currentOwner() == owner;

  /// The chat's notification: its whole current state (newest lines, oldest
  /// first), so a later post can never lose an earlier message. [picture] is
  /// the cached picture of the other person (1:1) or the group, or null; in a
  /// 1:1 it is also the sender's icon.
  static Future<void> _showChat(
    InboxChat chat, {
    required bool alert,
    required EffectiveAlert effective,
    Uint8List? picture,
  }) => _plugin.show(
    id: _idFor(chat.conversationId),
    title: chat.title,
    body: chat.group && chat.lines.last.sender.isNotEmpty
        ? '${chat.lines.last.sender}: ${chat.lines.last.text}'
        : chat.lines.last.text,
    payload: chat.conversationId,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        alertChannelId(effective),
        alertChannelName(effective),
        channelDescription: _channelDescription,
        playSound: effective.sound,
        sound: effective.tone == null
            ? null
            : UriAndroidNotificationSound(effective.tone!),
        enableVibration: effective.vibration,
        importance: Importance.high,
        priority: Priority.high,
        groupKey: _group,
        silent: !alert,
        onlyAlertOnce: !alert,
        number: chat.count,
        largeIcon: picture == null ? null : ByteArrayAndroidBitmap(picture),
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
                l.sender.isEmpty
                    ? null
                    : Person(
                        name: l.sender,
                        icon: picture == null || chat.group
                            ? null
                            : ByteArrayAndroidIcon(picture),
                      ),
              ),
          ],
        ),
      ),
      iOS: DarwinNotificationDetails(presentSound: effective.sound),
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
