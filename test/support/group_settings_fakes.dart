import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/group_event.dart';
import 'package:sis/features/chat/domain/group_settings_repository.dart';

/// A [GroupSettingsRepository] that behaves like the server, written from the
/// interface: every call takes [latency], a write can be refused with a typed
/// failure, and the live stream is not subscribed until [subscribeDelay] has
/// passed (a nudge sent before that is lost, as on a real channel).
class GroupSettingsFake implements GroupSettingsRepository {
  GroupSettingsFake({
    this.latency = const Duration(milliseconds: 5),
    this.subscribeDelay = const Duration(milliseconds: 20),
  });

  final Duration latency;
  final Duration subscribeDelay;

  /// Every call, in order: `settings:<id>:<avatar>:<add>:<hist>` (null shown
  /// as '-'), `delete:<id>`, `pictures:<id>`, 'subscribe'.
  final calls = <String>[];

  /// What the next writes answer; Ok by default.
  Result<void> setResult = const Ok(null);
  Result<void> deleteResult = const Ok(null);
  final pictures = <String, List<GroupEvent>>{};

  final _changes = StreamController<GroupChange>.broadcast();
  var _subscribed = false;

  /// Whether the stream handed out is live yet.
  bool get subscribed => _subscribed;

  /// A server nudge. Lost when nobody has subscribed yet.
  void nudge(String conversationId, String what) {
    if (_subscribed) {
      _changes.add((conversationId: conversationId, what: what));
    }
  }

  String _b(bool? v) => v == null ? '-' : '$v';

  @override
  Future<Result<void>> setSettings(
    String conversationId, {
    bool? membersCanSetAvatar,
    bool? membersCanAdd,
    bool? newMembersSeeHistory,
  }) async {
    calls.add(
      'settings:$conversationId:${_b(membersCanSetAvatar)}:'
      '${_b(membersCanAdd)}:${_b(newMembersSeeHistory)}',
    );
    await Future<void>.delayed(latency);
    return setResult;
  }

  @override
  Future<Result<void>> deleteGroup(String conversationId) async {
    calls.add('delete:$conversationId');
    await Future<void>.delayed(latency);
    return deleteResult;
  }

  @override
  Future<Result<List<GroupEvent>>> pictureEvents(String conversationId) async {
    calls.add('pictures:$conversationId');
    await Future<void>.delayed(latency);
    return Ok(pictures[conversationId] ?? const []);
  }

  @override
  Future<Result<Stream<GroupChange>>> groupChanges() async {
    calls.add('subscribe');
    await Future<void>.delayed(subscribeDelay);
    _subscribed = true;
    return Ok(_changes.stream);
  }
}
