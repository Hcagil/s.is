import 'dart:convert';

import 'package:crypto/crypto.dart';

/// One phone's identity inside a security code.
final class CodeParty {
  const CodeParty({
    required this.userId,
    required this.curve25519,
    required this.ed25519,
  });

  /// The member id (UUID with dashes).
  final String userId;

  /// Identity key: base64 of 32 bytes (padding may be missing).
  final String curve25519;

  /// Signing key: base64 of 32 bytes (padding may be missing).
  final String ed25519;
}

class _Raw {
  const _Raw(this.uuid, this.curve, this.ed);
  final List<int> uuid;
  final List<int> curve;
  final List<int> ed;
}

_Raw? _decode(CodeParty p) {
  final hex = p.userId.replaceAll('-', '');
  if (hex.length != 32) return null;
  try {
    final uuid = [
      for (var i = 0; i < 32; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ];
    final curve = base64.decode(base64.normalize(p.curve25519));
    final ed = base64.decode(base64.normalize(p.ed25519));
    if (curve.length != 32 || ed.length != 32) return null;
    return _Raw(uuid, curve, ed);
  } on FormatException {
    return null;
  }
}

int _cmp(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

String _digits30(_Raw p) {
  var h = <int>[0, 0, ...p.curve, ...p.ed, ...p.uuid];
  for (var i = 0; i < 5200; i++) {
    h = sha512.convert([...h, ...p.curve, ...p.ed]).bytes;
  }
  final out = StringBuffer();
  for (var c = 0; c < 30; c += 5) {
    var v = 0;
    for (var j = 0; j < 5; j++) {
      v = v * 256 + h[c + j];
    }
    out.write((v % 100000).toString().padLeft(5, '0'));
  }
  return out.toString();
}

/// The 60 digits both phones show for a pair of members, or null when an input is malformed or both ids are equal.
String? securityCode(CodeParty a, CodeParty b) {
  final x = _decode(a);
  final y = _decode(b);
  if (x == null || y == null) return null;
  final order = _cmp(x.uuid, y.uuid);
  if (order == 0) return null;
  return order < 0 ? _digits30(x) + _digits30(y) : _digits30(y) + _digits30(x);
}

/// The 60 digits as 3 lines of 4 groups of 5 digits; ArgumentError when [digits] is not 60 long.
List<String> securityCodeLines(String digits) {
  if (digits.length != 60) throw ArgumentError.value(digits.length, 'digits');
  return [
    for (var i = 0; i < 60; i += 20)
      [for (var j = 0; j < 20; j += 5) digits.substring(i + j, i + j + 5)]
          .join(' '),
  ];
}
