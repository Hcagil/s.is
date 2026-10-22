// The C entries the iPhone notification extension calls (rust/include/sis_crypto.h),
// against the real compiled library and real Olm messages made by the same
// vodozemac wrapper the app uses. Build it first:
//   cargo build --release --manifest-path rust/Cargo.toml
// Return codes: 0 ok, 1 bad argument, 2 pickle or key rejected, 3 cannot
// decrypt, 4 envelope refused, 5 output buffer too small, 6 internal error.
import 'dart:convert';
import 'dart:ffi';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sis/data/crypto/rust/api/olm.dart';
import 'package:sis/data/crypto/rust/frb_generated.dart';
import 'package:sis/features/chat/domain/message_envelope.dart';

final _lib = DynamicLibrary.open('rust/target/release/librust_lib_sis.so');
final _libc = DynamicLibrary.process();
final _malloc = _libc
    .lookupFunction<
      Pointer<Uint8> Function(IntPtr),
      Pointer<Uint8> Function(int)
    >('malloc');
final _free = _libc
    .lookupFunction<
      Void Function(Pointer<Uint8>),
      void Function(Pointer<Uint8>)
    >('free');

typedef _PrekeyC = Int32 Function(
  Pointer<Uint8>,
  Int32,
  Pointer<Uint8>,
  Size,
  Pointer<Size>,
);
typedef _Prekey = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Size>,
);
typedef _SessionC = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Int32,
  Pointer<Uint8>,
  Size,
  Pointer<Size>,
);
typedef _Session = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Size>,
);
typedef _InboundC = Int32 Function(
  Pointer<Uint8>,
  Size,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Int32,
  Pointer<Uint8>,
  Size,
  Pointer<Size>,
);
typedef _Inbound = int Function(
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  Pointer<Uint8>,
  int,
  Pointer<Uint8>,
  int,
  Pointer<Size>,
);

final _prekey = _lib.lookupFunction<_PrekeyC, _Prekey>(
  'sis_peek_prekey_session_id',
);
final _session = _lib.lookupFunction<_SessionC, _Session>('sis_peek_session');
final _inbound = _lib.lookupFunction<_InboundC, _Inbound>('sis_peek_inbound');

const preKeyType = 0;
const normalType = 1;

/// Native memory for one call; [free] releases all of it.
class Arena {
  final _all = <Pointer<Uint8>>[];

  Pointer<Uint8> bytes(List<int> b) {
    final ptr = _malloc(b.isEmpty ? 1 : b.length);
    ptr.asTypedList(b.isEmpty ? 1 : b.length).setAll(0, b);
    _all.add(ptr);
    return ptr;
  }

  /// NUL-terminated UTF-8 (or raw bytes, for a broken string).
  Pointer<Uint8> str(String s) => bytes([...utf8.encode(s), 0]);
  Pointer<Uint8> raw(List<int> b) => bytes([...b, 0]);

  Pointer<Size> size() {
    final ptr = _malloc(sizeOf<Size>());
    _all.add(ptr);
    final s = ptr.cast<Size>();
    s.value = 0xdead;
    return s;
  }

  void free() => _all.forEach(_free);
}

/// One call's result: the return code and, on 0, the text written.
typedef Out = ({int code, String? text, int len});

/// A real A→B exchange: [first] is A's pre-key message to B (B has no session
/// yet); after B accepted it, [reply] is B's normal message back to A.
class Fixture {
  Fixture({this.firstId = 'msg-1', this.firstText = 'merhaba şeker 🍬'}) {
    a = OlmAccount();
    b = OlmAccount();
    final otk = b.generateOneTimeKey();
    sa = a.createOutboundSession(
      theirIdentityKey: b.identityKey(),
      theirOneTimeKey: otk,
    );
    // B's account BEFORE the one-time key is used: what the store holds when
    // the push arrives.
    bAccountPickle = b.pickle(key: key);
    first = sa.encrypt(
      plaintext: utf8.encode(encodeEnvelope(id: firstId, text: firstText)),
    );
    final inbound = b.createInboundSession(
      theirIdentityKey: a.identityKey(),
      message: first,
    );
    sb = inbound.session;
    reply = sb.encrypt(
      plaintext: utf8.encode(encodeEnvelope(id: 'msg-2', text: 'cevap')),
    );
    aSessionPickle = sa.pickle(key: key);
  }

  static final key = Uint8List.fromList(List.generate(32, (i) => i * 7 + 1));
  final String firstId;
  final String firstText;
  late final OlmAccount a;
  late final OlmAccount b;
  late final OlmSession sa;
  late final OlmSession sb;
  late final String bAccountPickle;
  late final String aSessionPickle;
  late final OlmCiphertext first;
  late final OlmCiphertext reply;

  /// Any further A→B message encrypted with A's session (still pre-key: A has
  /// not decrypted a reply yet).
  OlmCiphertext aSays(Object plaintext) => sa.encrypt(
    plaintext: plaintext is String
        ? utf8.encode(plaintext)
        : plaintext as List<int>,
  );
}

String b64(OlmCiphertext c) => base64Encode(c.body);

Out _read(int code, Pointer<Uint8> out, Pointer<Size> len) {
  if (code != 0) return (code: code, text: null, len: len.value);
  return (
    code: 0,
    text: utf8.decode(out.asTypedList(len.value)),
    len: len.value,
  );
}

Out prekey(String ct, {int type = preKeyType, int cap = 256}) {
  final m = Arena();
  try {
    final out = m.bytes(List.filled(cap, 0));
    final len = m.size();
    return _read(_prekey(m.str(ct), type, out, cap, len), out, len);
  } finally {
    m.free();
  }
}

Out session({
  List<int>? key,
  required String pickle,
  required String messageId,
  required String ct,
  int type = normalType,
  int cap = 4096,
}) {
  final m = Arena();
  try {
    final k = key ?? Fixture.key;
    final out = m.bytes(List.filled(cap, 0));
    final len = m.size();
    final code = _session(
      m.bytes(k),
      k.length,
      m.str(pickle),
      m.str(messageId),
      m.str(ct),
      type,
      out,
      cap,
      len,
    );
    return _read(code, out, len);
  } finally {
    m.free();
  }
}

Out inbound({
  List<int>? key,
  required String accountPickle,
  required String identityKey,
  required String messageId,
  required String ct,
  int type = preKeyType,
  int cap = 4096,
}) {
  final m = Arena();
  try {
    final k = key ?? Fixture.key;
    final out = m.bytes(List.filled(cap, 0));
    final len = m.size();
    final code = _inbound(
      m.bytes(k),
      k.length,
      m.str(accountPickle),
      m.str(identityKey),
      m.str(messageId),
      m.str(ct),
      type,
      out,
      cap,
      len,
    );
    return _read(code, out, len);
  } finally {
    m.free();
  }
}

void main() {
  setUpAll(() async => RustLib.init());

  late Fixture f;
  setUp(() => f = Fixture());

  group('sis_peek_prekey_session_id', () {
    test('returns the session id the pre-key message opens', () {
      final r = prekey(b64(f.first));
      expect(r.code, 0);
      expect(r.text, f.sa.sessionId());
      expect(r.text, olmPreKeySessionId(message: f.first));
    });

    test('a normal message, or a pre-key type flag on it, is refused', () {
      expect(prekey(b64(f.reply), type: normalType).code, 1);
      expect(prekey(b64(f.first), type: 7).code, 1);
      expect(prekey(b64(f.reply), type: preKeyType).code, 3);
    });

    test('broken base64 or a body that is no Olm message is refused', () {
      expect(prekey('***not base64***').code, 1);
      expect(prekey(base64Encode(utf8.encode('hello'))).code, 3);
    });

    test('out too small gives 5; exactly the id length gives 0', () {
      final id = f.sa.sessionId();
      final n = utf8.encode(id).length;
      expect(prekey(b64(f.first), cap: n - 1).code, 5);
      final r = prekey(b64(f.first), cap: n);
      expect(r.code, 0);
      expect(r.text, id);
    });
  });

  group('sis_peek_inbound (no stored session)', () {
    Out peek({
      String? accountPickle,
      String? messageId,
      String? ct,
      String? identityKey,
      List<int>? key,
      int type = preKeyType,
      int cap = 4096,
    }) => inbound(
      key: key,
      accountPickle: accountPickle ?? f.bAccountPickle,
      identityKey: identityKey ?? f.a.identityKey(),
      messageId: messageId ?? f.firstId,
      ct: ct ?? b64(f.first),
      type: type,
      cap: cap,
    );

    test('decrypts the pre-key message to the envelope text', () {
      final r = peek();
      expect(r.code, 0);
      expect(r.text, f.firstText);
    });

    test('the account pickle is a copy: the same push opens again and the '
        'real account still accepts it', () {
      final before = f.bAccountPickle;
      expect(peek().code, 0);
      expect(peek().code, 0);
      expect(f.bAccountPickle, before);
      // The one-time key is still in the stored account: the app's own
      // receive path still works after the peek.
      final b2 = OlmAccount.fromPickle(pickle: before, key: Fixture.key);
      final inb = b2.createInboundSession(
        theirIdentityKey: f.a.identityKey(),
        message: f.first,
      );
      expect(
        decodeEnvelope(utf8.decode(inb.plaintext), f.firstId)?.text,
        f.firstText,
      );
    });

    test('envelope id is not message_id gives 4', () {
      expect(peek(messageId: 'msg-other').code, 4);
      expect(peek(messageId: '').code, 4);
    });

    test('wrong pickle key gives 2; a broken pickle gives 2', () {
      final wrong = List<int>.generate(32, (i) => 255 - i);
      expect(peek(key: wrong).code, 2);
      expect(peek(accountPickle: 'not a pickle').code, 2);
    });

    test('a key that is not 32 bytes gives 1', () {
      expect(peek(key: Fixture.key.sublist(0, 31)).code, 1);
      expect(peek(key: [...Fixture.key, 0]).code, 1);
    });

    test('a pre-key message for another account cannot be decrypted: 3', () {
      final other = OlmAccount();
      other.generateOneTimeKey();
      expect(peek(accountPickle: other.pickle(key: Fixture.key)).code, 3);
    });

    test('a normal (type 1) message is refused', () {
      expect(peek(ct: b64(f.reply), type: normalType).code, 1);
    });

    test('a wrong sender identity key cannot open it', () {
      expect(peek(identityKey: OlmAccount().identityKey()).code, 3);
      expect(
        peek(identityKey: 'not a key').code,
        isIn([1, 3]),
      ); // the header does not say which: bad argument or cannot decrypt
    });

    test('out too small gives 5; exactly the text length gives 0', () {
      final n = utf8.encode(f.firstText).length;
      expect(peek(cap: n - 1).code, 5);
      expect(peek(cap: 0).code, 5);
      final r = peek(cap: n);
      expect(r.code, 0);
      expect(r.text, f.firstText);
      expect(r.len, n);
    });
  });

  group('sis_peek_session (stored session)', () {
    Out peek({
      String? pickle,
      String? messageId,
      String? ct,
      List<int>? key,
      int type = normalType,
      int cap = 4096,
    }) => session(
      key: key,
      pickle: pickle ?? f.aSessionPickle,
      messageId: messageId ?? 'msg-2',
      ct: ct ?? b64(f.reply),
      type: type,
      cap: cap,
    );

    test('decrypts a normal message with a copy of the session', () {
      final r = peek();
      expect(r.code, 0);
      expect(r.text, 'cevap');
    });

    test('decrypts a pre-key message with the receiver session pickle', () {
      final m = f.aSays(encodeEnvelope(id: 'msg-3', text: 'ikinci'));
      expect(m.messageType, preKeyType);
      final r = session(
        pickle: f.sb.pickle(key: Fixture.key),
        messageId: 'msg-3',
        ct: b64(m),
        type: preKeyType,
      );
      expect(r.code, 0);
      expect(r.text, 'ikinci');
    });

    test('the session pickle is a copy: the same push opens twice and the '
        'stored session still decrypts it afterwards', () {
      final before = f.aSessionPickle;
      expect(peek().code, 0);
      expect(peek().code, 0);
      final s = OlmSession.fromPickle(pickle: before, key: Fixture.key);
      expect(
        decodeEnvelope(utf8.decode(s.decrypt(message: f.reply)), 'msg-2')?.text,
        'cevap',
      );
    });

    test('envelope id mismatch gives 4', () {
      expect(peek(messageId: 'msg-1').code, 4);
    });

    test('an envelope that is not v1, has no text, or is not JSON gives 4', () {
      for (final body in [
        jsonEncode({'v': 2, 'i': 'msg-9', 't': 'x'}),
        jsonEncode({'i': 'msg-9', 't': 'x'}),
        jsonEncode({'v': 1, 'i': 'msg-9'}),
        jsonEncode({'v': 1, 'i': 'msg-9', 't': 5}),
        jsonEncode(['v', 1]),
        'plain words',
      ]) {
        final m = f.sb.encrypt(plaintext: utf8.encode(body));
        final r = peek(messageId: 'msg-9', ct: b64(m));
        expect(r.code, 4, reason: body);
      }
    });

    test('a message from another session cannot be decrypted: 3', () {
      final g = Fixture();
      expect(peek(ct: b64(g.reply)).code, 3);
    });

    test('a tampered message cannot be decrypted: 3', () {
      final body = Uint8List.fromList(f.reply.body);
      body[body.length - 1] ^= 0x01; // inside the MAC
      expect(peek(ct: base64Encode(body)).code, 3);
    });

    test('wrong pickle key gives 2; a broken pickle gives 2', () {
      expect(peek(key: List<int>.generate(32, (i) => 255 - i)).code, 2);
      expect(peek(pickle: 'not a pickle').code, 2);
      // A valid pickle of an account is not a session pickle.
      expect(peek(pickle: f.bAccountPickle).code, 2);
    });

    test('bad arguments give 1', () {
      expect(peek(key: Fixture.key.sublist(0, 16)).code, 1);
      expect(peek(type: 2).code, 1);
      expect(peek(type: -1).code, 1);
    });

    test('out too small gives 5; exactly the text length gives 0', () {
      final n = utf8.encode('cevap').length;
      expect(peek(cap: n - 1).code, 5);
      final r = peek(cap: n);
      expect(r.code, 0);
      expect(r.text, 'cevap');
    });
  });

  test('the pickle and key buffers are byte-identical after a decrypt', () {
    final m = Arena();
    try {
      final out = m.bytes(List.filled(4096, 0));
      final len = m.size();
      final accBytes = [...utf8.encode(f.bAccountPickle), 0];
      final sesBytes = [...utf8.encode(f.aSessionPickle), 0];
      final k = m.bytes(Fixture.key);
      final acc = m.bytes(accBytes);
      final ses = m.bytes(sesBytes);
      final c1 = _inbound(
        k,
        32,
        acc,
        m.str(f.a.identityKey()),
        m.str(f.firstId),
        m.str(b64(f.first)),
        preKeyType,
        out,
        4096,
        len,
      );
      final c2 = _session(
        k,
        32,
        ses,
        m.str('msg-2'),
        m.str(b64(f.reply)),
        normalType,
        out,
        4096,
        len,
      );
      expect([c1, c2], [0, 0]);
      expect(acc.asTypedList(accBytes.length), accBytes);
      expect(ses.asTypedList(sesBytes.length), sesBytes);
      expect(k.asTypedList(32), Fixture.key);
    } finally {
      m.free();
    }
  });

  test('random message bodies never decrypt and never crash', () {
    final rnd = Random(7);
    for (var i = 0; i < 200; i++) {
      final ct = base64Encode(
        List.generate(rnd.nextInt(300), (_) => rnd.nextInt(256)),
      );
      final type = rnd.nextInt(2);
      expect(
        session(
          pickle: f.aSessionPickle,
          messageId: 'msg-2',
          ct: ct,
          type: type,
        ).code,
        inInclusiveRange(1, 5),
      );
      expect(
        inbound(
          accountPickle: f.bAccountPickle,
          identityKey: f.a.identityKey(),
          messageId: 'msg-1',
          ct: ct,
        ).code,
        inInclusiveRange(1, 5),
      );
    }
  });

  group('null pointers are bad arguments, never a crash', () {
    test('every pointer argument, one at a time', () {
      final m = Arena();
      try {
        final out = m.bytes(List.filled(4096, 0));
        final len = m.size();
        final k = m.bytes(Fixture.key);
        final ct = m.str(b64(f.first));
        final ctR = m.str(b64(f.reply));
        final acc = m.str(f.bAccountPickle);
        final ses = m.str(f.aSessionPickle);
        final idk = m.str(f.a.identityKey());
        final mid = m.str(f.firstId);
        final mid2 = m.str('msg-2');
        final n = nullptr.cast<Uint8>();
        final nl = nullptr.cast<Size>();

        expect(_prekey(n, 0, out, 4096, len), 1);
        expect(_prekey(ct, 0, n, 4096, len), 1);
        expect(_prekey(ct, 0, out, 4096, nl), 1);

        final s = [k, ses, mid2, ctR, out];
        for (var i = 0; i < s.length; i++) {
          final a = [...s]..[i] = n;
          expect(
            _session(a[0], 32, a[1], a[2], a[3], 1, a[4], 4096, len),
            1,
            reason: 'session arg $i null',
          );
        }
        expect(_session(k, 32, ses, mid2, ctR, 1, out, 4096, nl), 1);

        final ib = [k, acc, idk, mid, ct, out];
        for (var i = 0; i < ib.length; i++) {
          final a = [...ib]..[i] = n;
          expect(
            _inbound(a[0], 32, a[1], a[2], a[3], a[4], 0, a[5], 4096, len),
            1,
            reason: 'inbound arg $i null',
          );
        }
        expect(_inbound(k, 32, acc, idk, mid, ct, 0, out, 4096, nl), 1);

        // The same buffers still work: nothing above was a crash.
        expect(_session(k, 32, ses, mid2, ctR, 1, out, 4096, len), 0);
      } finally {
        m.free();
      }
    });

    test('a string that is not UTF-8 is a bad argument', () {
      final m = Arena();
      try {
        final out = m.bytes(List.filled(4096, 0));
        final len = m.size();
        final bad = m.raw([0xff, 0xfe, 0x41]);
        expect(_prekey(bad, 0, out, 4096, len), 1);
        expect(
          _session(
            m.bytes(Fixture.key),
            32,
            m.str(f.aSessionPickle),
            bad,
            m.str(b64(f.reply)),
            1,
            out,
            4096,
            len,
          ),
          1,
        );
      } finally {
        m.free();
      }
    });
  });
}
