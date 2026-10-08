import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/gallery.dart';
import '../domain/video.dart';
import '../domain/video_gallery.dart';
import 'video_grid_widgets.dart';

/// What the grid returns: the prepared videos (copied into the app's folder),
/// or [phonePicker] true when the member chose the phone's own picker
/// instead.
typedef VideoGridResult = ({VideoPick pick, bool phonePicker});

/// Opens the grid page; null when the member backs out.
Future<VideoGridResult?> showVideoGrid(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute<VideoGridResult>(builder: (_) => const VideoGridPage()),
    );

/// The phone's videos in a grid with their lengths: tick several, then
/// "Send (N)". Asks for video access itself and handles limited and denied
/// access.
class VideoGridPage extends ConsumerStatefulWidget {
  /// Creates the video grid page.
  const VideoGridPage({super.key});

  @override
  ConsumerState<VideoGridPage> createState() => _VideoGridPageState();
}

class _VideoGridPageState extends ConsumerState<VideoGridPage>
    with WidgetsBindingObserver {
  static const _pageSize = 60;
  // Trigger the next page this many pixels before the grid's physical end,
  // so the page is ready before the member reaches it.
  static const _loadMoreThreshold = 600.0;

  GalleryAccess? _access;
  List<GalleryVideo> _videos = const [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _nextPage = 0;
  // Bumped by every _load(); a _loadMore() in flight when a reload starts
  // discards its own stale result instead of appending it onto page 0.
  int _generation = 0;
  final _scroll = ScrollController();
  // Ticked videos, in tick order.
  final _picked = <GalleryVideo>[];
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        (_access == GalleryAccess.denied ||
            _access == GalleryAccess.permanentlyDenied)) {
      _load();
    }
  }

  void _onScroll() {
    if (!_hasMore || _loadingMore || _loading) return;
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels >= position.maxScrollExtent - _loadMoreThreshold) {
      _loadMore();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final gallery = ref.read(videoGalleryProvider);
    final access = await gallery.requestAccess();
    final videos =
        access == GalleryAccess.full || access == GalleryAccess.limited
        ? await gallery.recent(count: _pageSize)
        : const <GalleryVideo>[];
    if (!mounted || generation != _generation) return;
    setState(() {
      _access = access;
      _videos = videos;
      _loading = false;
      _nextPage = 1;
      _hasMore = videos.length == _pageSize;
      // A page still in flight from the old generation never clears this
      // itself (it returns early above), so the reload owns the reset.
      _loadingMore = false;
    });
  }

  Future<void> _loadMore() async {
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final page = await ref
          .read(videoGalleryProvider)
          .recent(page: _nextPage, count: _pageSize);
      if (!mounted || generation != _generation) return;
      setState(() {
        _videos = [..._videos, ...page];
        _nextPage++;
        _hasMore = page.length == _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _loadingMore = false);
      showSisNotice(
        context,
        AppLocalizations.of(context).videoLoadMoreFailed,
        isError: true,
      );
    }
  }

  Future<void> _selectMore() async {
    await ref.read(videoGalleryProvider).selectMore();
    if (!mounted) return;
    setState(() => _loading = true);
    await _load();
  }

  /// Copies the ticked videos into the app's folder while this page stays
  /// open (the button waits), then hands them back.
  Future<void> _send() async {
    if (_preparing || _picked.isEmpty) return;
    setState(() => _preparing = true);
    final pick = await ref
        .read(videoGalleryProvider)
        .prepare(List<GalleryVideo>.of(_picked));
    if (!mounted) return;
    Navigator.of(context).pop((pick: pick, phonePicker: false));
  }

  void _toggle(GalleryVideo v) {
    if (_preparing) return;
    final at = _picked.indexWhere((e) => e.id == v.id);
    if (at >= 0) {
      setState(() => _picked.removeAt(at));
    } else {
      setState(() => _picked.add(v));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(l.videoReviewTitle)),
        body: const Center(child: SisLoadingLogo()),
      );
    }
    if (_access == GalleryAccess.denied ||
        _access == GalleryAccess.permanentlyDenied) {
      return Scaffold(
        appBar: AppBar(title: Text(l.videoReviewTitle)),
        body: SafeArea(
          child: VideoAccessRequest(
            permanentlyDenied: _access == GalleryAccess.permanentlyDenied,
            onAllow: () {
              setState(() => _loading = true);
              _load();
            },
            onOpenSettings: () => ref.read(videoGalleryProvider).openSettings(),
            onPhonePicker: () =>
                Navigator.of(context)
                    .pop((pick: const VideoPick(), phonePicker: true)),
            onNotNow: () => Navigator.of(context).pop(),
          ),
        ),
      );
    }

    final limited = _access == GalleryAccess.limited;
    final body = _videos.isEmpty
        ? Center(child: Text(l.videoGridEmpty))
        : GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(3),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 3,
              crossAxisSpacing: 3,
            ),
            itemCount: _videos.length,
            itemBuilder: (context, i) {
              final v = _videos[i];
              return VideoGridTile(
                key: ValueKey('video-grid-${v.id}'),
                video: v,
                selected: _picked.any((e) => e.id == v.id),
                onTap: () => _toggle(v),
              );
            },
          );

    return PopScope(
      canPop: !_preparing,
      child: Scaffold(
        appBar: AppBar(
          title: Text(l.videoReviewTitle),
          actions: [
            if (limited)
              TextButton(
                key: const ValueKey('video-allow-more'),
                onPressed: _selectMore,
                child: Text(l.attachAllowMore),
              ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(child: body),
              SizedBox(
                height: 3,
                child: _loadingMore || _preparing
                    ? const SisProgressLine()
                    : null,
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                decoration: BoxDecoration(
                  color: t.surface,
                  border: Border(top: BorderSide(color: t.line)),
                ),
                child: SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    key: const ValueKey('video-send'),
                    onPressed: _picked.isEmpty || _preparing ? null : _send,
                    child: Text(l.videoSendCount(_picked.length)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
