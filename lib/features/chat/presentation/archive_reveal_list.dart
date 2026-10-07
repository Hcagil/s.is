import 'dart:async';

import 'package:flutter/material.dart';

/// Height of the "Archived chats" row; also how far the list is scrolled to hide it.
const double archiveRowHeight = 56;

/// The chat list with an optional [header] row hidden above the first chat.
/// Pulling down reveals it; scrolling hides it; a half-shown row snaps open or
/// shut when the finger lifts.
class ArchiveRevealList extends StatefulWidget {
  const ArchiveRevealList({
    super.key,
    required this.header,
    required this.itemCount,
    required this.itemBuilder,
    required this.separatorBuilder,
    required this.onRefresh,
  });

  /// null = no archived chats: plain list, no hidden row
  final Widget? header;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final IndexedWidgetBuilder separatorBuilder;
  final Future<void> Function() onRefresh;

  @override
  State<ArchiveRevealList> createState() => _ArchiveRevealListState();
}

class _ArchiveRevealListState extends State<ArchiveRevealList> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController(
      initialScrollOffset: widget.header != null ? archiveRowHeight : 0,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollEndNotification>(
      onNotification: _onScrollEnd,
      child: RefreshIndicator(
        onRefresh: widget.onRefresh,
        // Pulling down is what reveals the header, so refresh stands aside.
        notificationPredicate: widget.header == null
            ? defaultScrollNotificationPredicate
            : (_) => false,
        child: CustomScrollView(
          key: const ValueKey('conversation-list'),
          controller: _controller,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (widget.header != null)
              SliverToBoxAdapter(
                child: SizedBox(height: archiveRowHeight, child: widget.header),
              ),
            SliverList.separated(
              itemCount: widget.itemCount,
              itemBuilder: widget.itemBuilder,
              separatorBuilder: widget.separatorBuilder,
            ),
            if (widget.header != null)
              // Lets even a short list scroll far enough to hide the header.
              SliverLayoutBuilder(
                builder: (context, c) {
                  final filler =
                      (c.viewportMainAxisExtent +
                              archiveRowHeight -
                              c.precedingScrollExtent)
                          .clamp(0.0, double.infinity);
                  return SliverToBoxAdapter(child: SizedBox(height: filler));
                },
              ),
          ],
        ),
      ),
    );
  }

  bool _onScrollEnd(ScrollEndNotification n) {
    if (widget.header == null || n.depth != 0 || !_controller.hasClients) {
      return false;
    }
    final p = _controller.position.pixels;
    if (p > 0 && p < archiveRowHeight) {
      // Deferred: the position is still mid-`beginActivity` while this fires,
      // and an animation started now is overwritten by the idle activity.
      scheduleMicrotask(() {
        if (!mounted || !_controller.hasClients) return;
        unawaited(
          _controller.animateTo(
            p < archiveRowHeight / 2 ? 0 : archiveRowHeight,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          ),
        );
      });
    }
    return false;
  }

  @override
  void didUpdateWidget(covariant ArchiveRevealList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (oldWidget.header == null && widget.header != null) {
      // First archive: keep the chats where they are, row stays above.
      if (position.pixels > 0) position.correctBy(archiveRowHeight);
    } else if (oldWidget.header != null && widget.header == null) {
      // Last one unarchived: the row is gone, keep the chats where they are.
      position.correctBy(-position.pixels.clamp(0.0, archiveRowHeight));
    }
  }
}
