import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/auth/data/file_last_session_store.dart';
import 'package:sis/features/auth/domain/last_session.dart';
import 'package:sis/features/auth/domain/member.dart';

/// Helper to create a sample [LastSession] with deterministic values.
LastSession sampleLastSession({String userId = 'u1'}) {
  return LastSession(
    userId: userId,
    sessionId: 's1',
    me: const Member(
      userId: 'u1',
      displayName: 'Maya',
      tag: 'tag',
      avatarPath: '/avatar.png',
    ),
    onboarded: true,
    confirmedAt: DateTime.utc(2026, 10, 1, 12),
  );
}

/// Recursively checks that none of the keys in [json] match any of
/// the forbidden names.
bool _hasForbiddenKey(Map<String, dynamic> json, Set<String> forbidden) {
  for (final key in json.keys) {
    if (forbidden.contains(key)) return true;
    final value = json[key];
    if (value is Map<String, dynamic>) {
      if (_hasForbiddenKey(value, forbidden)) return true;
    } else if (value is List) {
      for (final item in value) {
        if (item is Map<String, dynamic>) {
          if (_hasForbiddenKey(item, forbidden)) return true;
        }
      }
    }
  }
  return false;
}

void main() {
  late Directory tempDir;
  late FileLastSessionStore store;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync(
      'file_last_session_store_test',
    );
    store = FileLastSessionStore(root: () async => tempDir);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('load() with no file returns null', () async {
    final session = await store.load();
    expect(session, isNull);
  });

  test('save() and load() round‑trip all fields', () async {
    final s = sampleLastSession();
    await store.save(s);
    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.userId, s.userId);
    expect(loaded.sessionId, s.sessionId);
    expect(loaded.me.userId, s.me.userId);
    expect(loaded.me.displayName, s.me.displayName);
    expect(loaded.me.tag, s.me.tag);
    expect(loaded.me.avatarPath, s.me.avatarPath);
    expect(loaded.onboarded, s.onboarded);
    expect(loaded.confirmedAt.isAtSameMomentAs(s.confirmedAt), isTrue);
  });

  test(
    'file content after save has correct structure and no sensitive data',
    () async {
      final s = sampleLastSession();
      await store.save(s);

      final file = File('${tempDir.path}/last_session.json');
      expect(file.existsSync(), isTrue);

      final text = await file.readAsString();
      final json = jsonDecode(text) as Map<String, dynamic>;

      // Top level keys
      expect(json.keys.toSet(), {'v', 'session'});

      // Version
      expect(json['v'], 1);

      final session = json['session'] as Map<String, dynamic>;
      expect(session.keys.toSet(), {
        'userId',
        'sessionId',
        'me',
        'onboarded',
        'confirmedAt',
      });

      // ConfirmedAt string ends with 'Z'
      final confirmedAtStr = session['confirmedAt'] as String;
      expect(confirmedAtStr.endsWith('Z'), isTrue);

      // No email or token keys anywhere
      final forbidden = {
        'email',
        'token',
        'access_token',
        'refresh_token',
        'accessToken',
        'refreshToken',
      };
      expect(_hasForbiddenKey(json, forbidden), isFalse);

      // Ensure raw file does not contain an email string
      expect(text.contains('maya@example.com'), isFalse);
    },
  );

  test('save a Member with email does not expose the email', () async {
    final memberWithEmail = Member(
      userId: 'u1',
      displayName: 'Maya',
      tag: 'tag',
      avatarPath: '/avatar.png',
      email: 'maya@example.com',
    );
    final s = LastSession(
      userId: 'u1',
      sessionId: 's1',
      me: memberWithEmail,
      onboarded: true,
      confirmedAt: DateTime.utc(2026, 10, 1, 12),
    );
    await store.save(s);

    final file = File('${tempDir.path}/last_session.json');
    final text = await file.readAsString();

    // Email string should not appear
    expect(text.contains('maya@example.com'), isFalse);

    // No forbidden keys
    final json = jsonDecode(text) as Map<String, dynamic>;
    final forbidden = {
      'email',
      'token',
      'access_token',
      'refresh_token',
      'accessToken',
      'refreshToken',
    };
    expect(_hasForbiddenKey(json, forbidden), isFalse);
  });

  test(
    'a valid v1 file written by hand loads (control for the cases below)',
    () async {
      await File('${tempDir.path}/last_session.json').writeAsString(
        jsonEncode({'v': 1, 'session': sampleLastSession().toJson()}),
      );
      expect((await store.load())?.userId, 'u1');
    },
  );

  group('malformed files', () {
    Future<void> write(String content) async {
      final file = File('${tempDir.path}/last_session.json');
      await file.writeAsString(content);
    }

    test('not JSON', () async {
      await write('not json');
      final session = await store.load();
      expect(session, isNull);
      expect(File('${tempDir.path}/last_session.json').existsSync(), isFalse);
    });

    test('empty array', () async {
      await write('[]');
      final session = await store.load();
      expect(session, isNull);
      expect(File('${tempDir.path}/last_session.json').existsSync(), isFalse);
    });

    test('wrong schema version', () async {
      await write(
        jsonEncode({'v': 2, 'session': sampleLastSession().toJson()}),
      );
      final session = await store.load();
      expect(session, isNull);
      expect(File('${tempDir.path}/last_session.json').existsSync(), isFalse);
    });

    test('wrong types', () async {
      await write(
        jsonEncode({
          'v': 1,
          'session': {'userId': 1},
        }),
      );
      final session = await store.load();
      expect(session, isNull);
      expect(File('${tempDir.path}/last_session.json').existsSync(), isFalse);
    });

    test('missing session key', () async {
      await write(jsonEncode({'v': 1}));
      final session = await store.load();
      expect(session, isNull);
      expect(File('${tempDir.path}/last_session.json').existsSync(), isFalse);
    });

    test('empty file', () async {
      await write('');
      final session = await store.load();
      expect(session, isNull);
      expect(File('${tempDir.path}/last_session.json').existsSync(), isFalse);
    });
  });

  test('clear() removes the file; no file does not throw', () async {
    final s = sampleLastSession();
    await store.save(s);
    final file = File('${tempDir.path}/last_session.json');
    expect(file.existsSync(), isTrue);

    await store.clear();
    expect(file.existsSync(), isFalse);

    // Clear again with no file
    await store.clear(); // should not throw
  });

  test('clear() racing a save in flight', () async {
    final s = sampleLastSession();
    final saveFuture = store.save(s);
    await store.clear();
    await saveFuture;

    final loaded = await store.load();
    expect(loaded, isNull);
    expect(File('${tempDir.path}/last_session.json').existsSync(), isFalse);
  });

  test('clear() racing with unawaited save', () async {
    final s = sampleLastSession();
    final saveFuture = store.save(s);
    final clearFuture = store.clear();
    await Future.wait([saveFuture, clearFuture]);

    final loaded = await store.load();
    expect(loaded, isNull);
    expect(File('${tempDir.path}/last_session.json').existsSync(), isFalse);
  });

  test('a save held before its write, then clear() completing, does not '
      'resurrect the file once the save resumes', () async {
    // The platform call behind the directory lookup is slow for the save and
    // fast for the clear: the clear finishes while the save is still in
    // flight, then the save writes.
    final held = Completer<void>();
    var calls = 0;
    final racy = FileLastSessionStore(
      root: () async {
        if (calls++ == 0) await held.future;
        return tempDir;
      },
    );
    final saving = racy.save(sampleLastSession());
    await racy.clear();
    held.complete();
    await saving;
    expect(File('${tempDir.path}/last_session.json').existsSync(), isFalse);
    expect(
      File('${tempDir.path}/last_session.json.part').existsSync(),
      isFalse,
    );
    expect(await racy.load(), isNull);
  });

  test('save twice: second overrides', () async {
    final s1 = sampleLastSession(userId: 'u1');
    final s2 = sampleLastSession(userId: 'u2');
    await store.save(s1);
    await store.save(s2);

    final loaded = await store.load();
    expect(loaded, isNotNull);
    expect(loaded!.userId, 'u2');
  });

  test('never throws when root throws', () async {
    final badStore = FileLastSessionStore(
      root: () async => throw const FileSystemException('x'),
    );

    // load should return null
    final loaded = await badStore.load();
    expect(loaded, isNull);

    // save should complete normally
    await badStore.save(sampleLastSession());

    // clear should complete normally
    await badStore.clear();
  });
}
