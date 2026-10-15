import 'package:flutter/painting.dart';

/// Width of a photo album in the chat, the same as a single photo's widest bubble.
const double albumWidth = 280;

/// Gap between two tiles.
const double albumGap = 2;

/// How many tiles an album of [count] photos draws: at most four; from the fifth photo on the fourth tile carries "+N".
int albumTiles(int count) => count < 4 ? count : 4;

/// The tile rectangles of an album of [count] (2 or more) photos, inside a box [albumWidth] wide. 2: two squares side by side. 3: one tall tile on the left, two squares stacked on the right. 4 or more: a 2x2 grid of squares.
List<Rect> albumRects(int count) {
  assert(count >= 2);
  final cell = (albumWidth - albumGap) / 2;
  switch (count) {
    case 2:
      return [
        Rect.fromLTWH(0, 0, cell, cell),
        Rect.fromLTWH(cell + albumGap, 0, cell, cell),
      ];
    case 3:
      return [
        Rect.fromLTWH(0, 0, cell, 2 * cell + albumGap),
        Rect.fromLTWH(cell + albumGap, 0, cell, cell),
        Rect.fromLTWH(cell + albumGap, cell + albumGap, cell, cell),
      ];
    default:
      return [
        Rect.fromLTWH(0, 0, cell, cell),
        Rect.fromLTWH(cell + albumGap, 0, cell, cell),
        Rect.fromLTWH(0, cell + albumGap, cell, cell),
        Rect.fromLTWH(cell + albumGap, cell + albumGap, cell, cell),
      ];
  }
}

/// Corners of the tile [tile] inside the album box [whole]: [outer] radius on a corner that lies on the box's edge, [inner] on a corner that touches another tile.
BorderRadius albumCorners(Rect tile, Rect whole, double outer, double inner) {
  final isLeft = (tile.left - whole.left).abs() < 0.01;
  final isTop = (tile.top - whole.top).abs() < 0.01;
  final isRight = (tile.right - whole.right).abs() < 0.01;
  final isBottom = (tile.bottom - whole.bottom).abs() < 0.01;
  Radius r(bool on) => Radius.circular(on ? outer : inner);
  return BorderRadius.only(
    topLeft: r(isLeft && isTop),
    topRight: r(isRight && isTop),
    bottomLeft: r(isLeft && isBottom),
    bottomRight: r(isRight && isBottom),
  );
}
