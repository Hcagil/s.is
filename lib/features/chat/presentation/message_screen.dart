import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../../notifications/application/push_controller.dart';
import '../../presence/application/presence_controllers.dart';
import '../../presence/domain/last_seen.dart';
import '../application/chat_controllers.dart';
import '../domain/highlight.dart';
import '../domain/links.dart';
import '../domain/message.dart';
import '../domain/read_marks.dart';
import 'attachment_sheet.dart';
import 'chat_search_bar.dart';
import 'swipeable_message.dart';
import 'conversation_list.dart';
import 'message_actions.dart';
import 'person_avatar.dart';
import 'photo_viewer.dart';
import 'profile_pages.dart';

/// The chat header's picture: the group's own, or the other member's for a
/// 1:1. Null while the list has not loaded [conversationId] yet.
String? _headerAvatar(WidgetRef ref, String? conversationId) {
  final conversation = (ref.watch(conversationListProvider).value ?? const [])
      .where((c) => c.id == conversationId)
      .firstOrNull;
  return conversation?.avatarPath ?? conversation?.other?.avatarPath;
}

/// Opens [conversationId] and closes it again when the screen is popped, so
/// the Realtime subscription lives exactly as long as the screen does.
///
/// [searchQuery] opens the screen with in-chat search already running that
/// query, [searchHitId] current -- the chat list's own search leads here.
Future<void> openConversation(
  BuildContext context,
  WidgetRef ref,
  String conversationId, {
  String? title,
  String? otherUserId,
  bool group = false,
  String? searchQuery,
  String? searchHitId,
}) async {
  final list = ref.read(conversationListProvider.notifier);
  // A conversation can be opened from inside another (a group member's page
  // -> Message); leaving it must hand the screen back to that one.
  final previous = ref.read(openConversationProvider);
  ref.read(openConversationProvider.notifier).open(conversationId);
  // Opening is reading. Not awaited: the screen must not wait on it.
  unawaited(list.markRead(conversationId));
  // Its notification leaves the shade.
  unawaited(ref.read(pushSourceProvider).clearConversation(conversationId));
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MessageScreen(
        title: title,
        otherUserId: otherUserId,
        group: group,
        initialSearchQuery: searchQuery,
        initialSearchHitId: searchHitId,
      ),
    ),
  );
  // Again on leaving, so a message that landed while the screen was open is
  // read before the list below re-reads the counts.
  await list.markRead(conversationId);
  if (previous == null) {
    ref.read(openConversationProvider.notifier).close();
  } else {
    ref.read(openConversationProvider.notifier).open(previous);
  }
  // The list is also kept live by Realtime; this re-read is the fallback when
  // that subscription could not be established.
  await ref.read(conversationListProvider.notifier).reloadQuietly();
}

/// "typing…" beats "online", which beats "last seen". In a 1:1 chat the
/// header already names the person, so it says just "typing…"; in a group,
/// who is typing by name.
String? _status(WidgetRef ref, String? other) {
  final typing = ref.watch(typingProvider);
  if (typing.isNotEmpty) {
    if (other != null) return 'typing…';
    if (typing.length > 1) return '${typing.length} people are typing…';
    final names = {
      for (final m in ref.watch(membersProvider).value ?? const []) m.userId: m,
    };
    final who = names[typing.first]?.displayName;
    return who == null ? 'typing…' : '$who is typing…';
  }
  if (other != null && ref.watch(onlineMembersProvider).contains(other)) {
    return 'online';
  }
  if (other != null) {
    final at = ref.watch(lastSeenProvider(other)).value;
    if (at != null) return lastSeenLabel(at, DateTime.now());
  }
  return null;
}

/// The open conversation: its messages, and a composer.
class MessageScreen extends ConsumerStatefulWidget {
  const MessageScreen({
    super.key,
    this.title,
    this.otherUserId,
    this.group = false,
    this.initialSearchQuery,
    this.initialSearchHitId,
  });

  final String? title;

  /// A group names each sender above their run of messages.
  final bool group;

  /// The other member of a 1:1, whose online status the header shows. Null
  /// for a group, where the header shows only who is typing.
  final String? otherUserId;

  /// Opens the screen with in-chat search already running this query (the
  /// chat list's own search leads here); null opens with the normal header.
  final String? initialSearchQuery;

  /// The hit made current once [initialSearchQuery] has run.
  final String? initialSearchHitId;

  @override
  ConsumerState<MessageScreen> createState() => _MessageScreenState();
}

class _MessageScreenState extends ConsumerState<MessageScreen> {
  final _scroll = ScrollController();
  final _bubbleKeys = <String, GlobalKey>{};

  /// The id of the message whose swipe action row is currently open, or
  /// null. At most one bubble's row is open at a time; scrolling the list
  /// closes it (see [initState]), as does a tap anywhere else in the list.
  final _openSwipeId = ValueNotifier<String?>(null);
  late bool _searching =
      widget.initialSearchQuery != null &&
      widget.initialSearchQuery!.trim().isNotEmpty;

  /// [widget.initialSearchHitId], until the search it came with produces
  /// hits and it is made current -- then null.
  late String? _pendingHitId = widget.initialSearchHitId;

  // ponytail: bubbles vary in height (text length, attachments), so there is
  // no exact item extent to jump to directly; this guess only needs to land
  // close enough that the target bubble gets built, and ensureVisible below
  // finishes the job exactly. Upgrade path: scrollable_positioned_list, if a
  // very long conversation ever makes the guess land too far off.
  static const _estimatedItemExtent = 72.0;

  /// Bumped by every `_goToHit`/`_closeSearch` call; a stale [_scrollTo]
  /// loop (or a stale `jumpToAround` follow-up) checks this and stops as
  /// soon as a newer call has superseded it.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_closeSwipeOnScroll);
  }

  void _closeSwipeOnScroll() {
    if (_openSwipeId.value != null) _openSwipeId.value = null;
  }

  @override
  void dispose() {
    _scroll.removeListener(_closeSwipeOnScroll);
    _scroll.dispose();
    _openSwipeId.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(String messageId) =>
      _bubbleKeys.putIfAbsent(messageId, GlobalKey.new);

  void _openSearch() => setState(() => _searching = true);

  Future<void> _closeSearch() async {
    final generation = ++_generation;
    ref.read(chatSearchProvider.notifier).close();
    ref.read(messagesProvider.notifier).returnToLive();
    setState(() => _searching = false);
    // The reload swaps the data under the same ListView/ScrollPosition and
    // nothing else moves the scroll back to the newest message once it
    // lands -- wait for it, then converge on it the same way as any hit.
    final live = await ref.read(messagesProvider.future);
    if (mounted && live.isNotEmpty && generation == _generation) {
      await _scrollTo(live.last.id, generation);
    }
  }

  /// Brings [hit] on screen: loads the window around it first when it is
  /// older than what is currently loaded.
  Future<void> _goToHit(Message hit) async {
    final generation = ++_generation;
    // Awaited rather than read from `.value`: right after this screen opens,
    // the live load can still be in flight, and reading a stale empty list
    // here would wrongly treat an about-to-load hit as needing its own
    // (redundant, racy) window -- see MessagesController.jumpToAround's
    // anchor-id guard for the other half of that race.
    final loaded = await ref.read(messagesProvider.future);
    if (generation != _generation) return; // superseded while awaiting
    if (!loaded.any((m) => m.id == hit.id)) {
      final result = await ref
          .read(messagesProvider.notifier)
          .jumpToAround(hit);
      if (generation != _generation) return; // superseded while awaiting
      if (result case Err(:final failure) when mounted) {
        showSisNotice(context, failure.message, isError: true);
        return;
      }
    }
    if (!mounted || generation != _generation) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _scrollTo(hit.id, generation),
    );
  }

  /// Brings [messageId] on screen, converging on it even far from the
  /// current position: bubbles vary too much in height for one guess to
  /// reliably land inside the target's build/cache window on a list this
  /// long. Each miss narrows a binary search using where a genuinely BUILT
  /// neighbour landed (found via [_nearestBuiltIndex]) instead of guessing
  /// again blind. [generation] stops this loop as soon as a newer
  /// `_goToHit`/`_closeSearch` call has started -- two of these racing on
  /// the same [_scroll] would otherwise fight each other.
  Future<void> _scrollTo(String messageId, int generation) async {
    if (!mounted || !_scroll.hasClients || generation != _generation) return;
    final list = ref.read(messagesProvider).value ?? const [];
    final matchIndex = list.indexWhere((m) => m.id == messageId);
    if (matchIndex < 0) return;
    // The list is reversed: display index 0 is the newest, at the bottom.
    final displayIndex = list.length - 1 - matchIndex;
    var low = 0.0;
    var high = _scroll.position.maxScrollExtent;
    var pixels = (displayIndex * _estimatedItemExtent).clamp(low, high);

    for (var attempt = 0; attempt < 24; attempt++) {
      if (!mounted || !_scroll.hasClients || generation != _generation) {
        return;
      }
      _scroll.jumpTo(pixels);
      await WidgetsBinding.instance.endOfFrame;
      final ctx = _bubbleKeys[messageId]?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 200),
        );
        return;
      }
      final nearest = _nearestBuiltIndex(list, matchIndex);
      if (nearest == null) return;
      // Larger matchIndex = newer = fewer pixels. A built neighbour newer
      // than the target means the target needs MORE pixels (scroll deeper);
      // older means it needs fewer.
      if (nearest > matchIndex) {
        low = pixels;
      } else {
        high = pixels;
      }
      if ((high - low).abs() < 1) return;
      pixels = (low + high) / 2;
    }
  }

  /// The index (in the same oldest-first [list] as [matchIndex]) of the
  /// message nearest [matchIndex] that currently has a built, mounted
  /// bubble -- or null if nothing is built at all. Scans outward from
  /// [matchIndex] both ways so the closest built neighbour wins.
  int? _nearestBuiltIndex(List<Message> list, int matchIndex) {
    for (var distance = 0; distance < list.length; distance++) {
      final before = matchIndex - distance;
      if (before >= 0 && _bubbleKeys[list[before].id]?.currentContext != null) {
        return before;
      }
      final after = matchIndex + distance;
      if (after < list.length &&
          after != before &&
          _bubbleKeys[list[after].id]?.currentContext != null) {
        return after;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final messages = ref.watch(messagesProvider);
    // Whose messages are "mine" comes from the session, not from the screen.
    final me = switch (ref.watch(sessionControllerProvider).value) {
      Allowed(:final member) => member.userId,
      _ => null,
    };
    // A message from someone ends their "typing…" at once rather than
    // leaving it over the message they just sent.
    ref.listen(messagesProvider, (previous, next) {
      final latest = next.value;
      if (latest == null || latest.isEmpty) return;
      if (previous?.value?.lastOrNull?.id == latest.last.id) return;
      ref.read(typingProvider.notifier).messageFrom(latest.last.senderId);
    });
    // Whenever the current hit changes -- a fresh search, next/previous, or
    // one selected before this screen even opened -- scroll to it.
    ref.listen(chatSearchProvider.select((s) => s.current), (previous, next) {
      if (next != null && next.id != previous?.id) {
        unawaited(_goToHit(next));
      }
    });
    // The chat list's own search opens this screen already asking for one
    // particular hit; make it current as soon as its search (run by
    // ChatSearchBar's own initState) produces results.
    ref.listen(chatSearchProvider.select((s) => s.hits), (previous, next) {
      final pending = _pendingHitId;
      if (pending != null && next.any((m) => m.id == pending)) {
        _pendingHitId = null;
        ref.read(chatSearchProvider.notifier).select(pending);
      }
    });
    final searchQuery = ref.watch(chatSearchProvider.select((s) => s.query));
    final currentHitId = ref.watch(
      chatSearchProvider.select((s) => s.current?.id),
    );
    final status = _status(ref, widget.otherUserId);
    final names = widget.group
        ? {
            for (final m in ref.watch(membersProvider).value ?? const [])
              m.userId: m.displayName,
          }
        : const <String, String>{};
    // Read status, where it is shared: your own messages look a little grey
    // until every sharing member has read them.
    final marks = ref.watch(readMarksProvider).value ?? const <ReadMark>[];
    final conversationId = ref.watch(openConversationProvider);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: _searching
            ? ChatSearchBar(
                initialQuery: widget.initialSearchQuery,
                onClose: _closeSearch,
              )
            : InkWell(
                key: const ValueKey('conversation-title'),
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  final id = conversationId;
                  if (id == null) return;
                  final page = widget.group
                      ? GroupScreen(
                          conversationId: id,
                          title: widget.title ?? 'Group',
                        )
                      : widget.otherUserId == null
                      ? null
                      // Already in this chat: no Message button on their page.
                      : PersonScreen(
                          userId: widget.otherUserId!,
                          fallbackName: widget.title,
                          fallbackAvatarPath: _headerAvatar(
                            ref,
                            conversationId,
                          ),
                          showMessage: false,
                        );
                  if (page == null) return;
                  Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => page));
                },
                child: SizedBox(
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Row(
                      children: [
                        PersonAvatar(
                          label: widget.title ?? 'Conversation',
                          seed:
                              widget.otherUserId ??
                              conversationId ??
                              widget.title ??
                              'Conversation',
                          radius: 18,
                          avatarPath: _headerAvatar(ref, conversationId),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.title ?? 'Conversation',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (status != null)
                                Text(
                                  status,
                                  key: const ValueKey('conversation-status'),
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
        actions: _searching
            ? null
            : [
                IconButton(
                  key: const ValueKey('chat-search-button'),
                  icon: const Icon(Icons.search),
                  onPressed: _openSearch,
                ),
              ],
      ),
      body: SisGlow(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => _openSwipeId.value = null,
                  child: switch (messages) {
                    AsyncData(:final value) when value.isEmpty => const Center(
                      child: Text('No messages yet. Say something.'),
                    ),
                    AsyncData(:final value) => ListView.builder(
                      controller: _scroll,
                      // Newest at the bottom, which is where the composer is.
                      reverse: true,
                      // Generous on purpose: a jump-to-hit needs the target
                      // bubble built even when it is far from the current
                      // scroll offset (see _scrollTo).
                      scrollCacheExtent: ScrollCacheExtent.pixels(2000),
                      itemCount: value.length,
                      itemBuilder: (context, i) {
                        final index = value.length - 1 - i;
                        final message = value[index];
                        final mine = me != null && message.isFrom(me);
                        final quoted = message.replyTo == null
                            ? null
                            : value
                                  .where((m) => m.id == message.replyTo)
                                  .firstOrNull;
                        final unread =
                            mine &&
                            !message.isDeleted &&
                            (message.isPending ||
                                !isReadByAnyone(marks, message.createdAt));
                        final allowedActions = allowedMessageActions(
                          message,
                          me: me,
                          now: DateTime.now(),
                          group: widget.group,
                        );
                        final bubble = SwipeableMessage(
                          key: _keyFor(message.id),
                          messageId: message.id,
                          mine: mine,
                          actions: allowedActions,
                          openId: _openSwipeId,
                          onOpenChanged: (open) {
                            if (open) {
                              _openSwipeId.value = message.id;
                            } else if (_openSwipeId.value == message.id) {
                              _openSwipeId.value = null;
                            }
                          },
                          onAction: (action) {
                            _openSwipeId.value = null;
                            runMessageAction(context, ref, message, action);
                          },
                          child: _Bubble(
                            message,
                            key: ValueKey('read-$unread-${message.id}'),
                            mine: mine,
                            unread: unread,
                            sender:
                                widget.group && !mine && startsRun(value, index)
                                ? (names[message.senderId] ?? 'Member')
                                : null,
                            quoted: quoted,
                            quotedName: quoted == null
                                ? null
                                : quoted.senderId == me
                                ? 'You'
                                : (names[quoted.senderId] ?? 'Member'),
                            highlightQuery: searchQuery,
                            isCurrentHit: message.id == currentHitId,
                          ),
                        );
                        return message.deletion == MessageDeletion.vanished
                            ? _Vanishing(
                                key: ValueKey('vanish-${message.id}'),
                                child: bubble,
                              )
                            : bubble;
                      },
                    ),
                    AsyncError(:final error) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          reasonOf(error),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                    _ => const Center(child: SisLoadingLogo()),
                  },
                ),
              ),
              const _Composer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(
    this.message, {
    super.key,
    required this.mine,
    required this.unread,
    this.sender,
    this.quoted,
    this.quotedName,
    this.highlightQuery,
    this.isCurrentHit = false,
  });

  final Message message;
  final bool mine;

  /// True for an own message no other member has read yet (or still
  /// sending). Shown as a thin yellow edge, never as a dimmed bubble.
  final bool unread;

  /// The message this one answers, when it is loaded here, and who wrote it.
  final Message? quoted;
  final String? quotedName;

  /// The sender's name, shown above the first bubble of their run in a group.
  final String? sender;

  /// The active in-chat search query, if any: every match in [message]'s
  /// body is highlighted.
  final String? highlightQuery;

  /// This bubble is the search's current hit -- shown with a purple edge,
  /// on either side, distinct from the amber "unread" edge (which stays on
  /// a merely-unread bubble that is not the current hit).
  final bool isCurrentHit;

  // The bubble's own outer cap and the two insets that eat into it: 12 px
  // padding, plus -- for a "mine" bubble, or the current search hit -- a
  // 1.5 px border that is always laid out (even transparent, when read).
  // _BodyWithTime measures its fits-inline decision against [_contentWidth],
  // not a copy of these numbers, so the two cannot drift apart.
  static const _maxWidth = 320.0;
  static const _hPad = 12.0;
  static const _borderWidth = 1.5;

  bool get _hasBorder => mine || isCurrentHit;

  double get _contentWidth =>
      _maxWidth - 2 * _hPad - (_hasBorder ? 2 * _borderWidth : 0);

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    // Square-ish corner on the sender's side marks whose bubble it is.
    const r = Radius.circular(8);
    const tail = Radius.circular(3);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: ValueKey('message-${message.id}'),
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: _hPad, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? null : brand.theirs,
          gradient: mine ? brand.gradient : null,
          borderRadius: BorderRadius.only(
            topLeft: r,
            topRight: r,
            bottomLeft: mine ? r : tail,
            bottomRight: mine ? tail : r,
          ),
          border: _hasBorder
              ? Border.all(
                  width: _borderWidth,
                  // The current hit is always the app's purple, distinct
                  // from the amber "unread" edge -- even on a bubble that
                  // is both unread and the current hit. A still-sending
                  // text message shows a clock mark instead of this edge.
                  color: isCurrentHit
                      ? Theme.of(context).colorScheme.primary
                      : (unread && !message.sending
                            ? brand.unreadEdge
                            : Colors.transparent),
                )
              : null,
        ),
        // Without this, a non-stretched Column still hands each child a
        // *loose* constraint up to the Container's own maxWidth (320): any
        // child that fills the space it is offered -- Align without a
        // widthFactor does, below -- reports back a width of 320, so the
        // Column (sized to its widest child) is 320 wide even for one short
        // word. IntrinsicWidth measures the content first and passes that
        // tight width down instead, so Align has nothing left to expand
        // into.
        child: IntrinsicWidth(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (message.deletion == MessageDeletion.placeholder)
                Row(
                  key: ValueKey('deleted-${message.id}'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.block,
                      size: 16,
                      color: mine
                          ? Colors.white70
                          : brand.text.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'This message was deleted',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontStyle: FontStyle.italic,
                          color: mine
                              ? Colors.white70
                              : brand.text.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ],
                ),
              if (message.forwarded)
                Padding(
                  key: ValueKey('forwarded-${message.id}'),
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.shortcut,
                        size: 14,
                        color: mine
                            ? Colors.white70
                            : brand.text.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Forwarded',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontStyle: FontStyle.italic,
                            color: mine
                                ? Colors.white70
                                : brand.text.withValues(alpha: 0.6),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (message.replyTo != null && !message.isDeleted)
                Container(
                  key: ValueKey('quote-${message.id}'),
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  decoration: BoxDecoration(
                    color: (mine ? Colors.white : brand.text).withValues(
                      alpha: 0.12,
                    ),
                    borderRadius: BorderRadius.circular(6),
                    border: Border(
                      left: BorderSide(
                        color: mine
                            ? Colors.white
                            : Theme.of(context).colorScheme.primary,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (quotedName != null)
                        Text(
                          quotedName!,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: mine
                                ? Colors.white
                                : Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      Text(
                        quoteText(quoted),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: mine ? Colors.white : brand.text,
                        ),
                      ),
                    ],
                  ),
                ),
              if (sender != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text(
                    sender!,
                    key: ValueKey('sender-${message.id}'),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: personTint(context, message.senderId, ink: true),
                    ),
                  ),
                ),
              if (message.hasAttachment) _Attachment(message),
              // An image may be sent without a caption, so an empty body must
              // render nothing at all rather than an empty line. A deleted
              // message never shows a time, but (defensively) may still carry
              // a body, so the two conditions stay independent below.
              if (message.body.isNotEmpty && !message.isDeleted)
                _BodyWithTime(
                  message: message,
                  bodyStyle: TextStyle(
                    fontSize: 15,
                    color: mine ? Colors.white : brand.text,
                  ),
                  linkColor: mine
                      ? Colors.white
                      : Theme.of(context).colorScheme.primary,
                  maxContentWidth: _contentWidth,
                  topPadding: message.hasAttachment ? 8 : 0,
                  timeText: message.isEdited
                      ? 'edited ${clockTime(message.createdAt)}'
                      : clockTime(message.createdAt),
                  timeStyle: TextStyle(
                    fontSize: 11,
                    color: (mine ? Colors.white : brand.text).withValues(
                      alpha: 0.6,
                    ),
                  ),
                  highlightQuery: highlightQuery,
                )
              else ...[
                if (message.body.isNotEmpty)
                  Padding(
                    padding: EdgeInsets.only(
                      top: message.hasAttachment ? 8 : 0,
                    ),
                    child: _LinkedText(
                      message.body,
                      key: ValueKey('body-${message.id}'),
                      style: TextStyle(
                        fontSize: 15,
                        color: mine ? Colors.white : brand.text,
                      ),
                      highlightQuery: highlightQuery,
                      linkColor: mine
                          ? Colors.white
                          : Theme.of(context).colorScheme.primary,
                    ),
                  ),
                if (!message.isDeleted)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        message.isEdited
                            ? 'edited ${clockTime(message.createdAt)}'
                            : clockTime(message.createdAt),
                        key: ValueKey('time-${message.id}'),
                        style: TextStyle(
                          fontSize: 11,
                          color: (mine ? Colors.white : brand.text).withValues(
                            alpha: 0.6,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A message body with its timestamp: inline at the end of the last line
/// when it fits there (WhatsApp-style, "ok  12:04"), otherwise dropped to
/// its own row below the body, bottom-right -- the layout the bubble used
/// before this widget existed.
///
/// [body] and [time] are always built as two separate widgets carrying their
/// original keys and exact text, never merged into one `Text`/`TextSpan`: a
/// widget test finds each with `find.text()` -- except a still-sending
/// bubble ([Message.sending]), whose time slot is an [Icon]
/// (`Icons.schedule_rounded`) under the same `time-<id>` key, found with
/// `find.byIcon`/`find.byKey` instead.
class _BodyWithTime extends StatelessWidget {
  const _BodyWithTime({
    required this.message,
    required this.bodyStyle,
    required this.linkColor,
    required this.maxContentWidth,
    required this.topPadding,
    required this.timeText,
    required this.timeStyle,
    this.highlightQuery,
  });

  final Message message;
  final TextStyle bodyStyle;
  final Color linkColor;

  /// The active in-chat search query, if any -- passed straight through to
  /// both [_LinkedText]s below.
  final String? highlightQuery;

  /// The bubble's real content column: its outer cap minus padding and,
  /// for a "mine" bubble, its always-laid-out border. Passed down from
  /// [_Bubble], which is the one place that inset is defined, so this
  /// widget never keeps its own copy of that arithmetic to drift from it.
  final double maxContentWidth;
  final double topPadding;
  final String timeText;
  final TextStyle timeStyle;

  static const _gap = 6.0;

  /// The pending-send icon's size, in place of the clock time while
  /// [Message.sending] -- close to [timeStyle]'s usual font size (11) so it
  /// reads as about the same weight in the same corner.
  static const _clockSize = 12.0;

  @override
  Widget build(BuildContext context) {
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    // Text/Text.rich merge the given style onto the ambient DefaultTextStyle
    // (which is where the app's Manrope font family comes from); a bare
    // TextStyle here would measure in the platform default font instead and
    // report the wrong width.
    final defaultStyle = DefaultTextStyle.of(context).style;
    // ponytail: measured as one plain span rather than the linked spans
    // _LinkedText actually renders -- a link's style only changes color and
    // underline, never font size/weight/family, so the two wrap identically.
    final bodyPainter = TextPainter(
      text: TextSpan(text: message.body, style: defaultStyle.merge(bodyStyle)),
      textDirection: direction,
      textScaler: scaler,
    )..layout(maxWidth: maxContentWidth);
    final lines = bodyPainter.computeLineMetrics();
    final lastLineWidth = lines.last.width;
    final bodyHeight = bodyPainter.height;
    var bodyWidth = 0.0;
    for (final line in lines) {
      if (line.width > bodyWidth) bodyWidth = line.width;
    }
    // Still sending: a small SIS icon takes the time's place -- never an
    // emoji, which draws from the phone's own font -- sized directly
    // rather than measured as text.
    double timeWidth;
    if (message.sending) {
      timeWidth = _clockSize;
    } else {
      final timePainter = TextPainter(
        text: TextSpan(text: timeText, style: defaultStyle.merge(timeStyle)),
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      timeWidth = timePainter.width;
      timePainter.dispose();
    }
    bodyPainter.dispose();

    // ponytail: RTL always drops to the own-row layout below, never inline.
    // The fits math above assumes a line's trailing edge is the column's
    // right edge (true for LTR); measuring an RTL line's *visual* end would
    // need glyph-level box positions, not just a summed width. Upgrade path:
    // measure with getBoxesForSelection (as the qa Measured helper does) if
    // RTL locales ever ship.
    final fits =
        direction != TextDirection.rtl &&
        lastLineWidth + _gap + timeWidth <= maxContentWidth;

    final timeWidget = message.sending
        ? Icon(
            Icons.schedule_rounded,
            key: ValueKey('time-${message.id}'),
            size: _clockSize,
            color: timeStyle.color,
          )
        : Text(timeText, key: ValueKey('time-${message.id}'), style: timeStyle);

    if (!fits) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.only(top: topPadding),
            child: _LinkedText(
              message.body,
              key: ValueKey('body-${message.id}'),
              style: bodyStyle,
              linkColor: linkColor,
              highlightQuery: highlightQuery,
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Align(alignment: Alignment.centerRight, child: timeWidget),
          ),
        ],
      );
    }

    // Widening to fit the time never needs more than the longest line
    // already wraps to (a longer earlier line already sets the bubble's
    // width) or the last line plus the time (a short, single-line message).
    final targetWidth = math.max(bodyWidth, lastLineWidth + _gap + timeWidth);
    return Padding(
      padding: EdgeInsets.only(top: topPadding),
      // A label/quote above the body can be wider than body+time, in which
      // case IntrinsicWidth makes the whole bubble that wide -- but a fixed
      // SizedBox here would still only claim targetWidth, stranding the
      // time mid-bubble instead of at the content's right edge. This custom
      // layout reports targetWidth for the intrinsic (hugging) pass -- same
      // as a Text's own intrinsic width -- but at real layout time fills
      // whatever width the column actually turns out to be, exactly the
      // way a plain Text/RenderParagraph already behaves (see the
      // IntrinsicWidth comment above): _Bubble's own hugging is unaffected,
      // because in the common case (no wider sibling) that real width is
      // targetWidth anyway.
      child: CustomMultiChildLayout(
        delegate: _BodyTimeLayout(
          targetWidth: targetWidth,
          bodyWidth: bodyWidth,
          bodyHeight: bodyHeight,
        ),
        children: [
          LayoutId(
            id: _BodyTimeSlot.body,
            child: _LinkedText(
              message.body,
              key: ValueKey('body-${message.id}'),
              style: bodyStyle,
              linkColor: linkColor,
              highlightQuery: highlightQuery,
            ),
          ),
          LayoutId(id: _BodyTimeSlot.time, child: timeWidget),
        ],
      ),
    );
  }
}

enum _BodyTimeSlot { body, time }

/// Lays the body out at its own (never stretched) [bodyWidth], and the time
/// at the bottom-right of the real column -- [targetWidth] only when nothing
/// wider forces the column open (see [_BodyWithTime]'s [CustomMultiChildLayout]
/// comment for why a plain SizedBox can't do both jobs at once).
class _BodyTimeLayout extends MultiChildLayoutDelegate {
  _BodyTimeLayout({
    required this.targetWidth,
    required this.bodyWidth,
    required this.bodyHeight,
  });

  final double targetWidth;
  final double bodyWidth;
  final double bodyHeight;

  @override
  Size getSize(BoxConstraints constraints) => Size(
    constraints.hasBoundedWidth ? constraints.maxWidth : targetWidth,
    bodyHeight,
  );

  @override
  void performLayout(Size size) {
    layoutChild(_BodyTimeSlot.body, BoxConstraints.tightFor(width: bodyWidth));
    positionChild(_BodyTimeSlot.body, Offset.zero);
    final timeSize = layoutChild(
      _BodyTimeSlot.time,
      BoxConstraints.loose(size),
    );
    positionChild(
      _BodyTimeSlot.time,
      Offset(size.width - timeSize.width, size.height - timeSize.height),
    );
  }

  @override
  bool shouldRelayout(covariant _BodyTimeLayout oldDelegate) =>
      targetWidth != oldDelegate.targetWidth ||
      bodyWidth != oldDelegate.bodyWidth ||
      bodyHeight != oldDelegate.bodyHeight;
}

/// A message deleted for everyone within its first hour: it shrinks and
/// fades away, then takes no space.
class _Vanishing extends StatefulWidget {
  const _Vanishing({super.key, required this.child});

  final Widget child;

  @override
  State<_Vanishing> createState() => _VanishingState();
}

class _VanishingState extends State<_Vanishing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _out = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  )..forward();

  late final Animation<double> _left = CurvedAnimation(
    parent: ReverseAnimation(_out),
    curve: Curves.easeInCubic,
  );

  @override
  void dispose() {
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _left,
    child: FadeTransition(opacity: _left, child: widget.child),
  );
}

/// An attachment, fetched through a signed URL issued only to a member.
///
/// The URL is short-lived, so it is resolved when the bubble is built rather
/// than stored with the message.
class _Attachment extends ConsumerWidget {
  const _Attachment(this.message);

  final Message message;

  /// The open conversation's photos, oldest first, and this one's place.
  void _view(BuildContext context, WidgetRef ref, String path) {
    final paths = [
      for (final m in ref.read(messagesProvider).value ?? const <Message>[])
        if (m.attachmentPath != null) m.attachmentPath!,
    ];
    final index = paths.indexOf(path);
    if (index < 0) return;
    openPhotoViewer(context, paths, index);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final path = message.attachmentPath;
    return GestureDetector(
      key: ValueKey('attachment-${path ?? message.id}'),
      onTap: path == null ? null : () => _view(context, ref, path),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 260, maxWidth: 280),
          child: switch ((message.localImage, path)) {
            // Your own photo, straight from the phone while it uploads.
            (final Uint8List local, null) => Stack(
              alignment: Alignment.center,
              children: [
                Image.memory(
                  local,
                  key: const ValueKey('attachment-local'),
                  cacheWidth: 560,
                  fit: BoxFit.cover,
                ),
                const SisLoadingLogo(size: 40),
              ],
            ),
            (_, final String path) => switch (ref.watch(
              attachmentBytesProvider(path),
            )) {
              AsyncData(:final value) => Image.memory(
                value,
                key: const ValueKey('attachment-image'),
                cacheWidth: 560,
                fit: BoxFit.cover,
                errorBuilder: (context, _, _) =>
                    _failed(context, 'Image unavailable'),
              ),
              AsyncError(:final error) => _failed(
                context,
                error is Failure ? error.message : 'Image unavailable',
              ),
              // The preview that came with the message, blurred, until the
              // photo is here.
              _ => switch (message.attachmentPreview) {
                final Uint8List preview => SizedBox(
                  height: 180,
                  width: 240,
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Image.memory(
                      preview,
                      key: const ValueKey('attachment-preview'),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      // Valid base64 can still be a broken image: then just
                      // wait for the photo.
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
                null => const SizedBox(
                  height: 120,
                  width: 180,
                  child: Center(child: SisLoadingLogo(size: 40)),
                ),
              },
            },
            _ => const SizedBox.shrink(),
          },
        ),
      ),
    );
  }

  Widget _failed(BuildContext context, String reason) => Container(
    height: 96,
    width: 180,
    alignment: Alignment.center,
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Text(reason, textAlign: TextAlign.center),
    ),
  );
}

class _Composer extends ConsumerStatefulWidget {
  const _Composer();

  @override
  ConsumerState<_Composer> createState() => _ComposerState();
}

class _ComposerState extends ConsumerState<_Composer> {
  final _controller = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    // A queued send for this conversation may have failed while the member
    // was elsewhere; restore it once the composer for it exists again.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final conversationId = ref.read(openConversationProvider);
      if (conversationId == null) return;
      final failure = ref
          .read(sendFailureProvider.notifier)
          .consume(conversationId);
      if (failure != null) _applyFailure(failure);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Puts a failed queued send's text and reply target back, and shows one
  /// notice -- whether the failure was caught live (the composer was
  /// already open when the server answered) or was waiting from before the
  /// composer existed (see [initState]).
  void _applyFailure(SendFailure failure) {
    final restored = failure.bodies.join('\n');
    _controller.text = _controller.text.isEmpty
        ? restored
        : '$restored\n${_controller.text}';
    _controller.selection = TextSelection.collapsed(
      offset: _controller.text.length,
    );
    if (failure.replyTo != null) {
      ref.read(replyingToProvider.notifier).start(failure.replyTo!);
    }
    if (mounted) showSisNotice(context, failure.failure.message, isError: true);
  }

  void _send() {
    final body = _controller.text;
    final editing = ref.read(editingProvider);
    // The same rule the database enforces, applied before the round trip. A
    // photo message's caption may be empty; a text-only message may not.
    final bodyOk = editing != null && editing.hasAttachment
        ? body.trim().length <= maxMessageLength
        : isSendableBody(body);
    if (_sending || !bodyOk) return;
    if (editing != null) {
      unawaited(_saveEdit(editing, body));
      return;
    }
    // Optimistic: MessagesController.send shows the pending bubble and
    // queues the round trip; the composer clears at once and does not wait
    // for it, so it stays usable while a send is in flight. A failure comes
    // back through sendFailureProvider (see the listener in build()).
    _controller.clear();
    unawaited(ref.read(messagesProvider.notifier).send(body));
  }

  Future<void> _saveEdit(Message editing, String body) async {
    setState(() => _sending = true);
    final result = await ref
        .read(messagesProvider.notifier)
        .editMessage(editing, body);
    if (!mounted) return;
    setState(() => _sending = false);
    switch (result) {
      case Ok():
        // Cleared only on success, so nothing a member typed is lost.
        _controller.clear();
        ref.read(editingProvider.notifier).clear();
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
    }
  }

  /// Picks and sends one or more images, with whatever is typed as the
  /// caption of the first one -- the rest go with no caption, one message
  /// per photo, same as any photo sent from the grid.
  Future<void> _attach() async {
    if (_sending) return;
    // The phone's own photos, or another app's. Closing the sheet without
    // choosing anything sends nothing.
    final picked = await showAttachmentSheet(context);
    if (picked.images.isEmpty || !mounted) return;
    setState(() => _sending = true);
    final body = _controller.text;
    final result = await ref
        .read(messagesProvider.notifier)
        .sendImages(picked.images, body: body);
    if (!mounted) return;
    setState(() => _sending = false);
    switch (result) {
      case Ok():
        _controller.clear();
        if (picked.dropped > 0) {
          showSisNotice(
            context,
            'Only the first 10 photos were sent.',
            isError: false,
          );
        }
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final replying = ref.watch(replyingToProvider);
    final editing = ref.watch(editingProvider);
    ref.listen(editingProvider, (previous, next) {
      if (next != null && previous?.id != next.id) {
        _controller.text = next.body;
        _controller.selection = TextSelection.collapsed(
          offset: _controller.text.length,
        );
      } else if (next == null && previous != null) {
        _controller.clear();
      }
    });
    // A queued send for this conversation failed while the composer was
    // already open: every unsent body comes back, oldest first (prepended
    // if the member has since typed something new -- it was typed earlier,
    // so it belongs first), the reply target too, one notice for the whole
    // stopped queue. [initState] covers the same failure resolving after
    // the member had already left.
    ref.listen(sendFailureProvider, (previous, next) {
      final conversationId = ref.read(openConversationProvider);
      if (conversationId == null) return;
      final failure = ref
          .read(sendFailureProvider.notifier)
          .consume(conversationId);
      if (failure != null) _applyFailure(failure);
    });
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(6, 8, 10, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (editing != null)
            _EditBar(editing)
          else if (replying != null)
            _ReplyBar(replying),
          Row(
            children: [
              IconButton(
                key: const ValueKey('composer-attach'),
                onPressed: _sending ? null : _attach,
                icon: const Icon(Icons.attach_file_rounded),
                tooltip: 'Send a photo',
              ),
              Expanded(
                child: TextField(
                  key: const ValueKey('composer-field'),
                  controller: _controller,
                  maxLength: maxMessageLength,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  // Throttled, and silent when the member does not share typing.
                  onChanged: (text) {
                    if (text.isNotEmpty) {
                      ref.read(typingProvider.notifier).signalTyping();
                    }
                  },
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    counterText: '',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                key: const ValueKey('composer-send'),
                onPressed: _sending ? null : _send,
                icon: const Icon(Icons.arrow_upward_rounded),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// What the composer is answering, with a way to stop.
class _ReplyBar extends ConsumerWidget {
  const _ReplyBar(this.message);

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(currentUserIdProvider);
    final name = message.senderId == me
        ? 'You'
        : (ref.watch(membersProvider).value ?? const [])
                  .where((m) => m.userId == message.senderId)
                  .firstOrNull
                  ?.displayName ??
              'Member';
    return Container(
      key: const ValueKey('reply-bar'),
      margin: const EdgeInsets.fromLTRB(10, 0, 0, 6),
      padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 3,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Replying to $name',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                Text(
                  quoteText(message),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('reply-cancel'),
            tooltip: 'Cancel reply',
            icon: const Icon(Icons.close),
            onPressed: () => ref.read(replyingToProvider.notifier).clear(),
          ),
        ],
      ),
    );
  }
}

/// What the composer is editing, with a way to stop.
class _EditBar extends ConsumerWidget {
  const _EditBar(this.message);

  final Message message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      key: const ValueKey('edit-bar'),
      margin: const EdgeInsets.fromLTRB(10, 0, 0, 6),
      padding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: Theme.of(context).colorScheme.primary,
            width: 3,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Editing message',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                Text(
                  quoteText(message),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('edit-cancel'),
            tooltip: 'Cancel edit',
            icon: const Icon(Icons.close),
            onPressed: () => ref.read(editingProvider.notifier).clear(),
          ),
        ],
      ),
    );
  }
}

/// A quoted message in one line: its text, "Photo", or what became of it.
String quoteText(Message? message) => switch (message) {
  null => 'Original message',
  Message(isDeleted: true) => 'This message was deleted',
  Message(:final body) when body.isNotEmpty => body,
  Message(hasAttachment: true) => '📷 Photo',
  _ => 'Message',
};

/// Message text with its links tappable, opening in the browser.
class _LinkedText extends ConsumerStatefulWidget {
  const _LinkedText(
    this.text, {
    super.key,
    required this.style,
    required this.linkColor,
    this.highlightQuery,
  });

  final String text;
  final TextStyle style;
  final Color linkColor;

  /// The active in-chat search query, if any: every match is highlighted,
  /// not just the current hit (see `_Bubble.isCurrentHit` for that).
  final String? highlightQuery;

  @override
  ConsumerState<_LinkedText> createState() => _LinkedTextState();
}

class _LinkedTextState extends ConsumerState<_LinkedText> {
  // One recognizer per link, disposed with the widget: a recognizer that is
  // never disposed leaks its gesture arena entry.
  final _taps = <TapGestureRecognizer>[];

  void _clear() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  Future<void> _open(Uri link) async {
    final opened = await ref.read(linkOpenerProvider).open(link);
    if (!opened && mounted) {
      showSisNotice(context, 'Could not open ${link.host}', isError: true);
    }
  }

  /// [text], split around every case-insensitive match of the active search
  /// query and given a highlighted background. Unlike a link's style, this
  /// never touches links (a match inside a link stays link-styled only --
  /// known simplification, links are rare inside a search hit).
  List<TextSpan> _highlightSpans(String text) {
    final query = widget.highlightQuery;
    if (query == null || query.trim().isEmpty) {
      return [TextSpan(text: text)];
    }
    final offsets = matchOffsets(text, query);
    if (offsets.isEmpty) {
      return [TextSpan(text: text)];
    }
    final length = query.trim().length;
    final spans = <TextSpan>[];
    var start = 0;
    for (final offset in offsets) {
      if (start < offset) {
        spans.add(TextSpan(text: text.substring(start, offset)));
      }
      spans.add(
        TextSpan(
          text: text.substring(offset, offset + length),
          // The app's own "unread" amber, reused as the search highlight.
          style: const TextStyle(
            backgroundColor: Color(0xFFFFD54F),
            color: Colors.black87,
          ),
        ),
      );
      start = offset + length;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start)));
    }
    return spans;
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    final segments = linkSegments(widget.text);
    final highlighting =
        widget.highlightQuery != null &&
        widget.highlightQuery!.trim().isNotEmpty;
    if (segments.every((s) => s.link == null) && !highlighting) {
      return Text(widget.text, style: widget.style);
    }
    final spans = <TextSpan>[];
    for (final s in segments) {
      final link = s.link;
      if (link == null) {
        spans.addAll(_highlightSpans(s.text));
        continue;
      }
      final tap = TapGestureRecognizer()..onTap = () => _open(link);
      _taps.add(tap);
      spans.add(
        TextSpan(
          text: s.text,
          recognizer: tap,
          style: TextStyle(
            color: widget.linkColor,
            decoration: TextDecoration.underline,
            decorationColor: widget.linkColor,
          ),
        ),
      );
    }
    return Text.rich(TextSpan(style: widget.style, children: spans));
  }
}
