import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/failure.dart';
import '../../../data/failures.dart';
import '../../../data/crypto/rust/api/admin_view_crypto.dart' as crypto;
import '../domain/admin_answer.dart';
import '../domain/admin_item.dart';
import '../domain/admin_link_phase.dart';
import '../domain/admin_panels_repository.dart';
import 'admin_bytes.dart';
import 'admin_key_store.dart';

/// [AdminPanelsRepository] backed by Supabase RPCs.
final class SupabaseAdminPanelsRepository implements AdminPanelsRepository {
  SupabaseAdminPanelsRepository(this._client, this._keys);

  final SupabaseClient _client;
  final AdminKeyStore _keys;

  /// The computer public key whose code status() last returned; confirmLink() pins only this one.
  List<int>? _shownComputer;

  Future<void> _lockTail = Future<void>.value();

  /// Runs [body] after every earlier locked call finished; a failure of one call never blocks the next.
  Future<T> _locked<T>(Future<T> Function() body) {
    final result = _lockTail.then((_) => body());
    _lockTail = result.then((_) {}, onError: (_) {});
    return result;
  }

  Failure _asFailure(Object e) => switch (e) {
    PostgrestException(:final code) when code == 'RLMT1' =>
      const SearchLimitFailure(),
    PostgrestException(:final code) when code == '42501' =>
      const DeniedFailure(),
    _ => readableFailure(e),
  };

  Future<Result<_ServerState?>> _state() async {
    try {
      final res = await _client.rpc('admin_view_state') as List<dynamic>;
      if (res.isEmpty) return const Ok(null);
      final r = res[0] as Map<String, dynamic>;
      return Ok(
        _ServerState(
          phonePub: byteaBytes(r['phone_pub']),
          computerPub: byteaBytes(r['computer_pub']),
          epoch: r['epoch'] as int,
        ),
      );
    } on PostgrestException catch (e) {
      return Err(_asFailure(e));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<AdminStatus?>> status() async {
    final s = await _state();
    switch (s) {
      case Err(:final failure):
        return Err(failure);
      case Ok(:final value):
        if (value == null) return const Ok(null);
        try {
          final k = await _keys.load();
          final computer = value.computerPub;
          final phase = linkPhase(
            ownKeyOnServer:
                k != null && k.published && sameBytes(value.phonePub, k.public),
            computerKeyPresent: computer != null,
            hasPin: k?.pinned != null,
            pinMatches: sameBytes(k?.pinned, computer),
          );
          final showCode =
              (phase == AdminLinkPhase.confirm ||
                  phase == AdminLinkPhase.changed) &&
              k != null &&
              computer != null;
          final code = showCode
              ? crypto.adminViewCode(
                  phonePublic: k.public,
                  computerPublic: computer,
                )
              : null;
          if (showCode) _shownComputer = computer;
          return Ok(AdminStatus(phase, code: code, epoch: value.epoch));
        } catch (e) {
          return Err(readableFailure(e));
        }
    }
  }

  @override
  Future<Result<AdminStatus>> startLink() => _locked(_startLinkBody);

  Future<Result<AdminStatus>> _startLinkBody() async {
    try {
      var k = await _keys.load();
      if (k == null) {
        final pair = crypto.adminViewGenerateKeypair();
        k = AdminKeys(secret: pair.secret, public: pair.public);
        await _keys.save(k);
      }

      final s = await _state();
      switch (s) {
        case Err(:final failure):
          return Err(failure);
        case Ok(:final value):
          if (value == null) return const Err(DeniedFailure());

          if (!k.published || !sameBytes(value.phonePub, k.public)) {
            final epoch = await _client.rpc(
              'admin_view_set_phone_key',
              params: {'p_pub': byteaParam(k.public)},
            ) as int;
            await _keys.save(
              k.withoutPin().copyWith(
                published: true,
                upEpoch: epoch,
                upSeq: 0,
                downEpoch: epoch,
                downSeq: 0,
              ),
            );
          }

          final r = await status();
          switch (r) {
            case Err(:final failure):
              return Err(failure);
            case Ok(value: final status):
              if (status == null) return const Err(DeniedFailure());
              return Ok(status);
          }
      }
    } on PostgrestException catch (e) {
      return Err(_asFailure(e));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  @override
  Future<Result<AdminStatus>> confirmLink() => _locked(_confirmLinkBody);

  Future<Result<AdminStatus>> _confirmLinkBody() async {
    try {
      final k = await _keys.load();
      if (k == null) return const Err(DeniedFailure());

      final s = await _state();
      switch (s) {
        case Err(:final failure):
          return Err(failure);
        case Ok(value: final serverState):
          if (serverState == null || serverState.computerPub == null) {
            return const Err(DeniedFailure());
          }
          final pin = sameBytes(serverState.computerPub, _shownComputer);
          if (pin) {
            await _keys.save(
              k.copyWith(
                pinned: serverState.computerPub,
                pinnedEpoch: serverState.epoch,
              ),
            );
          }
          final r = await status();
          switch (r) {
            case Err(:final failure):
              return Err(failure);
            case Ok(value: final st):
              if (st == null) return const Err(DeniedFailure());
              if (!pin) {
                return Ok(
                  AdminStatus(
                    AdminLinkPhase.changed,
                    code: st.code,
                    epoch: st.epoch,
                  ),
                );
              }
              return Ok(st);
          }
      }
    } on PostgrestException catch (e) {
      return Err(_asFailure(e));
    } catch (e) {
      return Err(_asFailure(e));
    }
  }

  /// The keys and the epoch, only while the link is confirmed and the pinned
  /// computer key is still the one on the server.
  Future<Result<(AdminKeys, int)>> _requireLinked() async {
    final r = await status();
    switch (r) {
      case Err(:final failure):
        return Err(failure);
      case Ok(value: final st):
        if (st == null || st.phase != AdminLinkPhase.linked) {
          return const Err(DeniedFailure());
        }
        final k = await _keys.load();
        if (k == null || k.pinned == null) return const Err(DeniedFailure());
        return Ok((k, st.epoch));
    }
  }

  @override
  Future<Result<List<AdminRow>>> fetch(int afterId) async {
    final linked = await _requireLinked();
    switch (linked) {
      case Err(:final failure):
        return Err(failure);
      case Ok(value: final pair):
        final (k, _) = pair;
        try {
          final res = await _client.rpc(
            'admin_view_fetch',
            params: {'p_after_id': afterId},
          ) as List<dynamic>;
          final rows = <AdminRow>[];
          for (final row in res) {
            final r = row as Map<String, dynamic>;
            final id = r['id'] as int;
            final e = r['epoch'] as int;
            final seq = r['seq'] as int;
            final body = byteaBytes(r['body']);
            AdminDown? m;
            if (body != null) {
              try {
                final plain = crypto.adminViewOpen(
                  mySecret: k.secret,
                  peerPublic: k.pinned!,
                  dir: 0,
                  epoch: e,
                  seq: BigInt.from(seq),
                  wire: body,
                );
                m = parseDown(utf8.decode(plain));
              } catch (_) {
                m = null;
              }
            }
            rows.add(AdminRow(id: id, epoch: e, seq: seq, message: m));
          }
          return Ok(rows);
        } on PostgrestException catch (e) {
          return Err(_asFailure(e));
        } catch (e) {
          return Err(_asFailure(e));
        }
    }
  }

  @override
  Future<Result<AdminSentRef?>> send(Map<String, Object?> message) =>
      _locked(() => _sendBody(message));

  Future<Result<AdminSentRef?>> _sendBody(Map<String, Object?> message) async {
    final linked = await _requireLinked();
    switch (linked) {
      case Err(:final failure):
        return Err(failure);
      case Ok(value: final pair):
        final (k, epoch) = pair;
        try {
          final seq = (k.upEpoch == epoch ? k.upSeq : 0) + 1;
          // Saved first: a sequence number is never reused, even when the send fails.
          await _keys.save(k.copyWith(upEpoch: epoch, upSeq: seq));
          final wire = crypto.adminViewSeal(
            mySecret: k.secret,
            peerPublic: k.pinned!,
            dir: 1,
            epoch: epoch,
            seq: BigInt.from(seq),
            plaintext: utf8.encode(jsonEncode(message)),
          );
          await _client.rpc(
            'admin_view_send',
            params: {
              'p_epoch': epoch,
              'p_seq': seq,
              'p_body': byteaParam(wire),
            },
          );
          return Ok(AdminSentRef(epoch, seq));
        } on PostgrestException catch (e) {
          // 22023 = the server refused our sequence or epoch; delete our key unless only the computer side changed.
          if (e.code == '22023') {
            final s = await _state();
            if (s case Ok(value: final v?)
                when sameBytes(v.phonePub, k.public) &&
                    (v.epoch != epoch || !sameBytes(v.computerPub, k.pinned))) {
              return const Err(DeniedFailure());
            }
            await _keys.delete();
            return const Err(DeniedFailure());
          }
          return Err(_asFailure(e));
        } catch (e) {
          return Err(_asFailure(e));
        }
    }
  }

  @override
  Future<int> lastDownSeq(int epoch) async {
    final k = await _keys.load();
    return k != null && k.downEpoch == epoch ? k.downSeq : 0;
  }

  @override
  Future<void> saveLastDownSeq(int epoch, int seq) =>
      _locked(() => _saveLastDownSeqBody(epoch, seq));

  Future<void> _saveLastDownSeqBody(int epoch, int seq) async {
    final k = await _keys.load();
    if (k == null) return;
    if (k.downEpoch != epoch || seq > k.downSeq) {
      await _keys.save(k.copyWith(downEpoch: epoch, downSeq: seq));
    }
  }

  @override
  Future<void> forget() => _keys.delete();
}

final class _ServerState {
  const _ServerState({
    required this.phonePub,
    required this.computerPub,
    required this.epoch,
  });
  final List<int>? phonePub;
  final List<int>? computerPub;
  final int epoch;
}
