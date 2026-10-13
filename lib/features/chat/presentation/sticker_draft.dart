import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// All drawing coordinates are in a 200 x 200 space.
const double stickerSpace = 200;

/// The eight colours of the text and pen screens.
const List<Color> makerColours = [
  Color(0xFFFFFFFF),
  Color(0xFF111111),
  Color(0xFFFF5C7A),
  Color(0xFFFFB020),
  Color(0xFFFFE066),
  Color(0xFF4FD18B),
  Color(0xFF4DA3FF),
  Color(0xFFB06BFF),
];

/// The three fonts of the text screen.
enum MakerFont { sans, serif, hand }

/// One stroke, points in sticker space. For the cut-out brush [erase] true
/// erases and false restores; the pen ignores it.
class MakerStroke {
  /// Creates a stroke.
  MakerStroke({
    required this.points,
    required this.width,
    this.colour = const Color(0xFFFFFFFF),
    this.erase = false,
  });

  /// The path.
  final List<Offset> points;

  /// The width in sticker space.
  final double width;

  /// The pen colour.
  final Color colour;

  /// Erase (true) or restore (false), for the cut-out brush.
  final bool erase;
}

/// One piece of text on the sticker.
class MakerText {
  /// Creates a text piece.
  MakerText({
    this.text = '',
    this.position = const Offset(100, 100),
    this.colour = const Color(0xFFFFFFFF),
    this.font = MakerFont.sans,
    this.size = 24,
  });

  /// The words.
  String text;

  /// The centre, in sticker space.
  Offset position;

  /// The colour.
  Color colour;

  /// The font.
  MakerFont font;

  /// The font size in sticker space.
  double size;
}

/// Everything the member has made so far, shared by the maker screens.
class StickerDraft extends ChangeNotifier {
  /// The 512 x 512 square photo.
  ui.Image? photo;

  /// A 512 x 512 image whose alpha is the cut-out, once it is ready.
  ui.Image? mask;

  /// Whether "Cut-out" (not "Whole image") is chosen.
  bool cutOut = false;

  /// Whether this phone can cut a subject out of a photo.
  bool cutOutSupported = false;

  /// The album the maker was started from (its Add button), or null.
  String? entryAlbumId;

  /// Set once the draft is disposed; late results are dropped.
  bool closed = false;

  /// Erase and restore strokes, in the order they were made.
  final List<MakerStroke> brush = [];

  /// Pen strokes.
  final List<MakerStroke> pen = [];

  /// Text pieces.
  final List<MakerText> texts = [];

  /// Whether a cut-out is ready.
  bool get hasCutOut => mask != null;

  /// Sets the square photo.
  void setPhoto(ui.Image image) {
    photo = image;
    notifyListeners();
  }

  /// Sets the cut-out from 512 x 512 alpha bytes.
  Future<void> setMask(Uint8List alpha512) async {
    if (alpha512.length != 512 * 512) return;
    final rgba = Uint8List(512 * 512 * 4);
    for (var i = 0; i < 512 * 512; i++) {
      rgba[i * 4] = 255;
      rgba[i * 4 + 1] = 255;
      rgba[i * 4 + 2] = 255;
      rgba[i * 4 + 3] = alpha512[i];
    }
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      rgba,
      512,
      512,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    final image = await done.future;
    if (closed) {
      image.dispose();
      return;
    }
    mask = image;
    notifyListeners();
  }

  /// Chooses "Cut-out" (true) or "Whole image" (false).
  void setCutOut(bool on) {
    cutOut = on;
    notifyListeners();
  }

  /// Adds [s] to [list] (the brush or the pen).
  void addStroke(List<MakerStroke> list, MakerStroke s) {
    list.add(s);
    notifyListeners();
  }

  /// Extends the last stroke of [list].
  void addPoint(List<MakerStroke> list, Offset p) {
    list.last.points.add(p);
    notifyListeners();
  }

  /// Undoes the last brush stroke.
  void undoBrush() {
    if (brush.isNotEmpty) brush.removeLast();
    notifyListeners();
  }

  /// Forgets every brush stroke.
  void resetBrush() {
    brush.clear();
    notifyListeners();
  }

  /// Undoes the last pen stroke.
  void undoPen() {
    if (pen.isNotEmpty) pen.removeLast();
    notifyListeners();
  }

  /// Forgets every pen stroke.
  void clearPen() {
    pen.clear();
    notifyListeners();
  }

  /// Adds a text piece.
  void addText(MakerText t) {
    texts.add(t);
    notifyListeners();
  }

  /// Removes a text piece.
  void removeText(MakerText t) {
    texts.remove(t);
    notifyListeners();
  }

  /// Tells listeners a text piece was edited in place.
  void changed() => notifyListeners();

  /// Drops pen strokes past the first [count] (cancel on the draw screen).
  void restorePen(int count) {
    if (pen.length > count) pen.removeRange(count, pen.length);
    notifyListeners();
  }

  @override
  void dispose() {
    closed = true;
    photo?.dispose();
    mask?.dispose();
    super.dispose();
  }
}
