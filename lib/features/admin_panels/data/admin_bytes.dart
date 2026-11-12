import 'dart:typed_data';

// The backslash character, spelled by code so no escaping can go wrong.
final String _bs = String.fromCharCode(0x5c);

/// The bytea parameter text for [bytes]: backslash, 'x', then two lowercase hex digits per byte.
String byteaParam(List<int> bytes) {
  final buffer = StringBuffer('${_bs}x');
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// The bytes of a bytea text from the server, or null when [v] is not a String starting with backslash+'x', has an odd number of hex digits, or any pair is not valid hex.
Uint8List? byteaBytes(Object? v) {
  if (v is! String) return null;
  if (!v.startsWith('${_bs}x')) return null;
  final hexPart = v.substring(2);
  if (hexPart.length % 2 != 0) return null;
  final length = hexPart.length ~/ 2;
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    final byte = int.tryParse(hexPart.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    bytes[i] = byte;
  }
  return bytes;
}

/// True when both are non-null and have the same length and the same elements.
bool sameBytes(List<int>? a, List<int>? b) {
  if (a == null || b == null) return false;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
