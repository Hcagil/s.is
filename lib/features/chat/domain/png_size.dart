import 'dart:typed_data';

/// Width and height from a PNG header (the IHDR chunk is always first: width
/// at bytes 16-19, height at 20-23, big-endian). Null for anything that is
/// not a PNG with a non-zero size.
({int width, int height})? pngDimensions(Uint8List? png) {
  if (png == null || png.length < 24) return null;
  if (png[0] != 0x89 || png[1] != 0x50 || png[2] != 0x4E || png[3] != 0x47) {
    return null;
  }
  final data = ByteData.sublistView(png);
  final width = data.getUint32(16);
  final height = data.getUint32(20);
  if (width == 0 || height == 0) return null;
  return (width: width, height: height);
}
