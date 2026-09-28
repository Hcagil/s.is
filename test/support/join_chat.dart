// A ChatFake whose list-wide Realtime join behaves like the real one
// (SupabaseChatRepository.incomingAll): the join takes as long as the test
// says -- possibly forever -- and once it is confirmed, the stream it hands
// back is single-subscription, so inserts the server sends between the
// confirmation and the caller's listen() are held for that listener, not
// dropped. Inserts sent before the join is confirmed are not delivered at
// all, exactly as on the wire.
//
// Written from the ChatRepository contract and the stream kind of the real
// repository, never from ConversationListController.
import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/message.dart';

import 'fakes.dart';

class _Join {
  final done = Completer<void>();
  List<Message> atJoin = const [];
}

class JoinChat extends ChatFake {
  JoinChat({super.latency, super.self});

  _Join? _join;
  final _live = <StreamController<Message>>[];

  /// Joins confirmed, listened to, and cancelled -- one per incomingAll().
  int joins = 0;
  int listens = 0;
  int cancels = 0;

  /// Runs the moment a caller listens to a joined stream.
  void Function()? onListen;

  /// The next join is not confirmed until [confirmJoin] -- or ever.
  void holdJoin() => _join = _Join();

  /// Confirms every held join. [atJoin] are inserts the server sends in the
  /// same instant, before the caller has the stream in hand: they sit in the
  /// stream until someone listens.
  void confirmJoin({List<Message> atJoin = const []}) {
    final j = _join;
    _join = null;
    if (j == null) return;
    j.atJoin = atJoin;
    for (final m in atJoin) {
      // The inserts are rows now, whoever hears of them.
      _record(m);
    }
    j.done.complete();
  }

  /// Whether a joined stream currently has a listener.
  bool get listening => _live.any((c) => c.hasListener);

  void _record(Message m) {
    // The "database" side of ChatFake.deliver, without a Realtime push: no
    // subscription of ChatFake's own exists here, so this only stores.
    super.deliver(m);
  }

  @override
  void deliver(Message m) {
    _record(m);
    for (final c in [..._live]) {
      if (!c.isClosed) c.add(m);
    }
  }

  @override
  Future<Result<Stream<Message>>> incomingAll() async {
    calls.add('incomingAll');
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    final held = _join;
    var pending = const <Message>[];
    if (held != null) {
      await held.done.future;
      pending = held.atJoin;
    }
    if (incomingAllResult case final failed?) return failed;
    joins++;
    late final StreamController<Message> c;
    c = StreamController<Message>(
      onListen: () {
        listens++;
        onListen?.call();
      },
      onCancel: () {
        cancels++;
        _live.remove(c);
      },
    );
    for (final m in pending) {
      c.add(m);
    }
    _live.add(c);
    return Ok(c.stream);
  }
}
