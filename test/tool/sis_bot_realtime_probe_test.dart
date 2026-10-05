@Tags(['sis_bot_probe'])
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The SIS Bot gets no Realtime: joining any private channel with the bot's
/// REAL access token is refused by the server (realtime_receive carries
/// `not is_bot(auth.uid())`), while a human member joins the same topics.
///
/// Driven by test/tool/sis_bot_tool_test.sh, which bootstraps the bot on the
/// local stack and passes both tokens in. Its own tag (dart_test.yaml) keeps it
/// out of every other run, including `--run-skipped --tags integration`, which
/// would override a plain `skip:`: without a bootstrapped bot there is nothing
/// to probe.
const _url = String.fromEnvironment(
  'SUPABASE_TEST_URL',
  defaultValue: 'http://host.docker.internal:54321',
);
const _key = String.fromEnvironment(
  'SUPABASE_TEST_KEY',
  defaultValue: 'sb_publishable_ACJWlzQHlZjBrEguHvfOxg_3BJgxAaH',
);
const _botJwt = String.fromEnvironment('SIS_BOT_PROBE_JWT');
const _humanJwt = String.fromEnvironment('SIS_BOT_PROBE_HUMAN_JWT');
const _debug = String.fromEnvironment('SIS_BOT_PROBE_DEBUG');

/// A client whose Realtime connection carries [jwt], as a signed-in app's does.
Future<SupabaseClient> _as(String jwt) async {
  final c = SupabaseClient(_url, _key);
  await c.realtime.setAuth(jwt);
  return c;
}

/// Joins [topic] on a fresh connection (a refused join can hold up the next
/// one on the same socket, turning a refusal into a timeout). Presence is
/// enabled on presence:members, as the app does, so the presence branch of
/// the policy is the one asked.
Future<RealtimeSubscribeStatus> _join(String jwt, String topic) async {
  final c = await _as(jwt);
  addTearDown(c.dispose);
  final first = Completer<RealtimeSubscribeStatus>();
  final channel = c.channel(
    topic,
    opts: const RealtimeChannelConfig(private: true),
  );
  if (topic == 'presence:members') channel.onPresenceSync((_) {});
  channel.subscribe((status, _) {
    if (!first.isCompleted) first.complete(status);
  });
  return first.future.timeout(
    const Duration(seconds: 15),
    onTimeout: () => RealtimeSubscribeStatus.timedOut,
  );
}

void main() {
  final skip = _botJwt.isEmpty
      ? 'run by test/tool/sis_bot_tool_test.sh (needs a bootstrapped bot)'
      : null;
  final topics = [
    'presence:members',
    if (_debug.isNotEmpty) 'typing:$_debug',
    if (_debug.isNotEmpty) 'reads:$_debug',
  ];

  test('control: a human Debug member joins every topic', () async {
    for (final t in topics) {
      expect(
        await _join(_humanJwt, t),
        RealtimeSubscribeStatus.subscribed,
        reason: t,
      );
    }
  }, skip: skip);

  test('the bot cannot join presence, typing or read marks', () async {
    for (final t in topics) {
      expect(
        await _join(_botJwt, t),
        isNot(RealtimeSubscribeStatus.subscribed),
        reason: t,
      );
    }
  }, skip: skip);
}
