import 'dart:convert';
import 'dart:developer';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// A compile-time constant: callers gate on it, so release builds drop the hook.
const kTestLogin = bool.fromEnvironment('SIS_TEST_LOGIN');

/// Test builds only (--dart-define=SIS_TEST_LOGIN=true). Reads a refresh token
/// from test_session.json in the app's support directory (put there by
/// tool/sis_test_send.sh), deletes the file, then signs in with it. Nothing
/// else can start a session this way. Without the define it does nothing and
/// never touches the disk.
Future<bool> consumeTestSession({
  required Future<void> Function(String refreshToken) signIn,
  Future<Directory> Function()? root,
  bool enabled = kTestLogin,
}) async {
  if (!enabled) return false;
  final dir = await (root ?? getApplicationSupportDirectory)();
  final file = File('${dir.path}/test_session.json');
  if (!await file.exists()) return false;
  String? token;
  try {
    final raw = jsonDecode(await file.readAsString()) as Map<String, Object?>;
    final value = raw['refresh_token'];
    if (value is String && value.isNotEmpty) token = value;
  } catch (_) {
    // An unreadable file means no token.
  } finally {
    try {
      await file.delete();
    } catch (_) {
      // Nothing more to do if the delete fails.
    }
  }
  if (token == null) return false;
  try {
    await signIn(token);
    return true;
  } catch (e) {
    log('Test sign-in failed: ${e.runtimeType}', name: 'sis.startup');
    return false;
  }
}
