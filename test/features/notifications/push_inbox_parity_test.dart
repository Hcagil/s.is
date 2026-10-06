// Update 1 slice 11a: with the app closed, Android's receiver (PushInbox.kt,
// InstantPush.kt) now writes the notification inbox itself, and the Dart
// handler that Doze runs 10-50 minutes later leaves it alone: since Update 1
// it draws nothing on Android. Written from the contract, not the code.
//
// Two halves:
// - Parity: test/fixtures/push_inbox_vectors.json is also read by
//   android/app/src/test/kotlin/com/esd/sis/PushInboxTest.kt. Both languages
//   are held to the same inbox JSON, summary, picture path and cache file
//   name, so neither can drift alone.
// - The seam: the native write cannot run here, so it is reproduced as it
//   lands in the preferences file -- the inbox JSON under
//   "flutter.sis.push_inbox.<owner>" (NativeReceiver in push_platform.dart)
//   -- and the real onBackgroundPush runs afterwards in a fresh isolate.
//
// Device fakes: test/support/push_platform.dart. Run under TZ=JST-9.
import 'dart:convert';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_core_platform_interface/test.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/auth/domain/member.dart';
import 'package:sis/features/chat/data/file_attachment_cache.dart';
import 'package:sis/features/chat/data/file_chat_list_snapshot_store.dart';
import 'package:sis/features/chat/domain/conversation.dart';
import 'package:sis/features/notifications/data/firebase_push_source.dart';
import 'package:sis/features/notifications/data/local_push_display.dart';
import 'package:sis/features/notifications/domain/notification_inbox.dart';

import '../../support/push_platform.dart';

const _prefsChannel = MethodChannel('plugins.flutter.io/shared_preferences');
const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _owner = 'member-a';
const _inboxKey = 'flutter.sis.push_inbox.$_owner';
const _msg = '6f1b7c1e-2a55-4c1f-9e0a-0d7f7b1a2c3d';

final _vectors = jsonDecode(
  File('test/fixtures/push_inbox_vectors.json').readAsStringSync(),
) as Map<String, Object?>;

List<InboxChat> _parse(String? raw) => raw == null
    ? []
    : [
        for (final c in jsonDecode(raw) as List)
          InboxChat.fromJson(Map<String, Object?>.from(c as Map)),
      ];

Object? _json(List<InboxChat> inbox) =>
    jsonDecode(jsonEncode([for (final c in inbox) c.toJson()]));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  group('parity with PushInbox.kt (shared vectors)', () {
    for (final v in (_vectors['adds']! as List).cast<Map<String, Object?>>()) {
      test('add: ${v['name']}', () {
        var inbox = _parse(v['start'] as String?);
        for (final s in (v['steps']! as List).cast<Map<String, Object?>>()) {
          inbox = addToInbox(
            inbox,
            conversationId: s['conversation_id']! as String,
            title: s['title']! as String,
            body: s['text']! as String,
            sender: s['sender'] as String?,
            chat: s['chat'] as String?,
            messageId: s['message_id'] as String?,
            at: DateTime.fromMillisecondsSinceEpoch(s['at']! as int),
          );
        }
        expect(_json(inbox), v['inbox']);
      });
    }

    test('the line limit is the shared one', () {
      expect(maxInboxLines, _vectors['max_lines']);
    });

    for (final v
        in (_vectors['summaries']! as List).cast<Map<String, Object?>>()) {
      test('summary: "${v['text']}"', () {
        expect(inboxSummary(_parse(jsonEncode(v['inbox']))), v['text']);
      });
    }

    test('cache file names are Uri.encodeComponent', () {
      for (final v
          in (_vectors['cache_names']! as List).cast<Map<String, Object?>>()) {
        expect(Uri.encodeComponent(v['path']! as String), v['file']);
      }
    });
  });

  // The real snapshot store and attachment cache, where production puts them,
  // so the vectors Kotlin is held to are what the phone really holds.
  group('the files the native side reads', () {
    late Directory support;
    late Directory cache;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('sis-support-');
      cache = await Directory.systemTemp.createTemp('sis-cache-');
      messenger.setMockMethodCallHandler(
        _pathChannel,
        (call) async => switch (call.method) {
          'getApplicationSupportDirectory' => support.path,
          'getApplicationCacheDirectory' => cache.path,
          _ => throw MissingPluginException(call.method),
        },
      );
    });

    tearDown(() async {
      messenger.setMockMethodCallHandler(_pathChannel, null);
      await support.delete(recursive: true);
      await cache.delete(recursive: true);
    });

    test('the vector snapshot is what the chat list store writes', () async {
      await FileChatListSnapshotStore().save(_owner, const [
        Conversation(
          id: 'c1',
          other: Member(
            userId: 'u-ava',
            displayName: 'Ava',
            avatarPath: 'u-ava/pic.jpg',
          ),
        ),
        Conversation(id: 'g1', title: 'Team', avatarPath: 'groups/g1.jpg'),
        Conversation(
          id: 'c3',
          other: Member(userId: 'u-cy', displayName: 'Cy'),
        ),
      ]);
      final files = support.listSync(recursive: true).whereType<File>();
      expect(files, hasLength(1));
      final avatars = _vectors['avatars']! as Map<String, Object?>;
      expect(
        jsonDecode(files.single.readAsStringSync()),
        jsonDecode(avatars['snapshot']! as String),
      );
    });

    test('the attachment cache names each file as the vectors say', () async {
      final names = (_vectors['cache_names']! as List)
          .cast<Map<String, Object?>>();
      for (final v in names) {
        await FileAttachmentCache().write(v['path']! as String, Uint8List(1));
      }
      final written = {
        for (final f in cache.listSync(recursive: true).whereType<File>())
          f.path.split('/').last,
      };
      expect(written, {for (final v in names) v['file']});
    });
  });

  group('after the native receiver wrote the inbox', () {
    late Shade shade;
    late DiskPrefs disk;

    setUpAll(() async {
      setupFirebaseCoreMocks();
      await Firebase.initializeApp();
    });

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      shade = Shade();
      disk = DiskPrefs();
      messenger.setMockMethodCallHandler(Shade.channel, shade.handle);
      messenger.setMockMethodCallHandler(_prefsChannel, disk.handle);
      SharedPreferences.resetStatic();
      await LocalPushDisplay.init();
      await LocalPushDisplay.forUser(_owner);
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(Shade.channel, null);
      messenger.setMockMethodCallHandler(_prefsChannel, null);
    });

    test('the late Dart handler leaves the native inbox and the native '
        'notification as they are: it draws and stores nothing', () async {
      const message = RemoteMessage(
        data: {
          'conversation_id': 'g1',
          'title': 'Ben @ Team',
          'body': 'late but here',
          'sender': 'Ben',
          'chat': 'Team',
          'message_id': _msg,
          'user_id': _owner,
        },
      );
      expect(NativeReceiver(shade, disk).receive(message.data), isTrue);
      final inbox = disk.values[_inboxKey];
      final drawn = Map<int, Object?>.of(shade.posted);
      SharedPreferences.resetStatic();
      shade.calls.clear();

      await onBackgroundPush(message);

      expect(disk.values[_inboxKey], inbox);
      final g1 = _parse(disk.values[_inboxKey] as String?).single;
      expect(g1.lines, hasLength(1));
      expect(g1.count, 1);
      expect(shade.posted, drawn);
      expect(shade.calls, isNot(contains('show')));
    });
  });
}
