import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/brand.dart';
import '../../../app/delivery_tick.dart';
import '../../../app/grey_option.dart';
import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../../appearance/presentation/chat_text_scale.dart';
import '../../appearance/presentation/chat_wallpaper.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/session_state.dart';
import '../../notifications/application/push_controller.dart';
import '../../presence/application/presence_controllers.dart';
import '../../presence/presentation/last_seen_text.dart';
import '../../update/presentation/whats_new_card.dart';
import '../application/chat_controllers.dart';
import '../application/chat_drafts.dart';
import '../application/group_controller.dart';
import '../domain/conversation.dart';
import '../domain/delivery.dart';
import '../domain/emoji.dart';
import '../domain/group_member.dart';
import '../domain/highlight.dart';
import '../domain/links.dart';
import '../domain/message.dart';
import '../domain/png_size.dart';
import '../domain/reaction.dart';
import '../domain/timeline.dart';
import '../domain/read_marks.dart';
import 'attachment_preview_page.dart';
import 'attachment_sheet.dart';
import 'chat_search_bar.dart';
import 'group_event_line.dart';
import 'group_gone_guard.dart';
import 'swipeable_message.dart';
import 'message_actions.dart';
import 'member_name.dart';
import 'message_menu_card.dart';
import 'person_avatar.dart';
import 'photo_viewer.dart';
import 'profile_pages.dart';
import 'readers_card.dart';

part 'message_bubble.dart';
part 'reaction_chips.dart';
part 'seen_by_pill.dart';
part 'reactions_bar.dart';
part 'message_body_with_time.dart';
part 'message_attachment.dart';
part 'message_composer.dart';
part 'linked_text.dart';
part 'jump_to_latest.dart';

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
  // The caller's `ref` dies with its widget (a list tile can be rebuilt away
  // while the chat is open); the container lives as long as the app.
  final container = ProviderScope.containerOf(context);
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
  // Only while this chat is still the open one: the member may already have
  // opened another during the markRead above, and closing (or restoring
  // `previous`) then would pull that chat's messages out from under it.
  if (container.read(openConversationProvider) == conversationId) {
    if (previous == null) {
      container.read(openConversationProvider.notifier).close();
    } else {
      container.read(openConversationProvider.notifier).open(previous);
    }
  }
  // The list is also kept live by Realtime; this re-read is the fallback when
  // that subscription could not be established.
  await container.read(conversationListProvider.notifier).reloadQuietly();
}

/// "typing…" beats "online", which beats "last seen". In a 1:1 chat the
/// header already names the person, so it says just "typing…"; in a group,
/// who is typing by name.
String? _status(WidgetRef ref, AppLocalizations l, String? other) {
  final typing = ref.watch(typingProvider);
  if (typing.isNotEmpty) {
    if (other != null) return l.statusTyping;
    if (typing.length > 1) return l.statusPeopleTyping(typing.length);
    final names = {
      for (final m in ref.watch(yourPeopleProvider).value ?? const [])
        m.userId: m,
    };
    final who = names[typing.first]?.displayName;
    return who == null ? l.statusTyping : l.statusWhoTyping(who);
  }
  if (other != null && ref.watch(onlineMembersProvider).contains(other)) {
    return l.statusOnline;
  }
  if (other != null) {
    final at = ref.watch(lastSeenProvider(other)).value;
    if (at != null) return lastSeenText(l, at, DateTime.now());
  }
  return null;
}

bool _isIos(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.iOS;

/// The bottom safe-area inset the composer covers itself on iPhone (the home
/// indicator; 0 while the keyboard is open, when the keyboard is the edge).
/// Android: 0 -- its SafeArea handles the gesture bar as before.
double _composerBottomInset(BuildContext context) =>
    _isIos(context) ? MediaQuery.paddingOf(context).bottom : 0;

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
    _scroll.addListener(_maybeLoadOlder);
  }

  /// The list is reversed: "after" is older, "before" is newer. Near the top
  /// of what is loaded, asks for the next older page; near the bottom of a
  /// jumped window, for the next newer page (see loadNewer). Cheap when
  /// nothing is left. Also keeps [_far] -- whether the newest message is more
  /// than a screen away -- which shows the jump-to-latest button.
  void _maybeLoadOlder() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final far = position.extentBefore > position.viewportDimension;
    final messages = ref.read(messagesProvider.notifier);
    // Back at the newest message after being away: check nothing was missed.
    if (_far.value && !far) messages.verifyNewest();
    _far.value = far;
    if (position.extentAfter < 600) unawaited(messages.loadOlder());
    if (position.extentBefore < 600) unawaited(messages.loadNewer());
  }

  /// True while the list is more than a screen above its newest message.
  final _far = ValueNotifier<bool>(false);

  /// Jump to the newest message. Nothing waits on the network: a jumped
  /// window is swapped for the live list synchronously (returnToLive), and
  /// the scroll starts in the same frame as the tap.
  void _toLatest() {
    _generation++; // stops any search scroll still converging
    final messages = ref.read(messagesProvider.notifier);
    final jumped = messages.isJumped;
    if (jumped) messages.returnToLive();
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (jumped) {
      position.jumpTo(0);
      return;
    }
    // Far away: skip most of the distance, glide the last two screens.
    final near = position.viewportDimension * 2;
    if (position.pixels > near) position.jumpTo(near);
    unawaited(
      position.animateTo(
        0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  @override
  void dispose() {
    _far.dispose();
    _scroll.dispose();
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

  /// A long press on a message: closes the keyboard, then opens the action
  /// card above the bubble (below it when there is no room), the pressed
  /// bubble lit. Photo, link and quote taps are handled deeper in the bubble
  /// and win over this.
  Future<void> _openActionCard(Message message, {required bool mine}) async {
    FocusManager.instance.primaryFocus?.unfocus();
    // The bubble moves while the keyboard drops, so the card is placed after
    // it settles; capped at 30 frames.
    if (View.of(context).viewInsets.bottom > 0) {
      for (
        var i = 0;
        i < 30 && mounted && View.of(context).viewInsets.bottom > 0;
        i++
      ) {
        await WidgetsBinding.instance.endOfFrame;
      }
      if (!mounted) return;
    }
    final anchor = _bubbleRect(message.id);
    await showMessageMenu(
      context,
      ref,
      message,
      anchor: anchor,
      alignEnd: mine,
    );
  }

  /// Sets or clears (null) the member's reaction on [messageId] and closes the
  /// tap extras; a refusal shows a notice (this screen outlives the bar).
  Future<void> _react(String messageId, String? emoji) async {
    ref.read(tappedMessageProvider.notifier).clear();
    final r = await ref
        .read(reactionsProvider.notifier)
        .react(messageId, emoji);
    if (r case Err(:final failure) when mounted) {
      showSisNotice(context, failure.message, isError: true);
    }
  }

  /// The bubble's rectangle in global coordinates, or null when it is not on
  /// screen. The bubble Container's own 12/4 margin is part of its box and is
  /// removed, so the lift hugs the bubble.
  Rect? _bubbleRect(String messageId) {
    final root = _bubbleKeys[messageId]?.currentContext;
    if (root == null) return null;
    RenderBox? box;
    void find(Element e) {
      if (box != null) return;
      if (e.widget.key == ValueKey('message-$messageId')) {
        box = e.renderObject as RenderBox?;
        return;
      }
      e.visitChildren(find);
    }

    (root as Element).visitChildren(find);
    final b = box;
    if (b == null || !b.attached) return null;
    final r = b.localToGlobal(Offset.zero) & b.size;
    return Rect.fromLTRB(r.left + 12, r.top + 4, r.right - 12, r.bottom - 4);
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
      // A page that did not fill the screen, or one that just landed, may
      // still leave the top in reach: look again once laid out.
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoadOlder());
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
    final conversationId = ref.watch(openConversationProvider);
    listenGroupGone(context, ref, conversationId);
    // Not given by the caller (a tapped notification opens this screen before
    // the list is known): taken from the list as soon as it has the chat.
    final listed = ref.watch(
      conversationListProvider.select(
        (s) => (s.value ?? const <Conversation>[])
            .where((c) => c.id == conversationId)
            .firstOrNull,
      ),
    );
    final title =
        widget.title ??
        (listed == null
            ? null
            : conversationLabel(AppLocalizations.of(context), listed));
    final isGroup = widget.group || (listed?.isGroup ?? false);
    final isSystem = listed?.isSystem ?? false;
    final otherUserId = widget.otherUserId ?? listed?.other?.userId;
    final status = _status(ref, AppLocalizations.of(context), otherUserId);
    // The group's own roster names every sender, current or departed --
    // yourPeopleProvider would miss someone no longer reachable, and would
    // also pull in people reachable only through some OTHER shared chat.
    // Also what greys a departed sender's name in their own bubbles.
    final roster = isGroup && conversationId != null
        ? ref.watch(groupRosterProvider(conversationId)).value ??
              const <GroupMember>[]
        : const <GroupMember>[];
    final names = {
      for (final m in roster)
        m.member.userId: nameOrMember(
          AppLocalizations.of(context),
          m.member.displayName,
        ),
    };
    final departedSenderIds = {
      for (final m in roster)
        if (m.hasLeft) m.member.userId,
    };
    // Each sender's colour slot, from the group's roster (empty in a 1:1).
    final slotByUser = {for (final m in roster) m.member.userId: m.colorSlot};
    // Keeps the read and delivery marks loaded and live for the whole chat
    // (an auto-dispose provider the rows would otherwise only start when one
    // of your own messages is on screen). The select never changes, so this
    // screen does not rebuild on a tick: each of your bubbles watches its own.
    ref.watch(readMarksProvider.select((_) => null));
    // Same for the reactions: one load and one live subscription per open
    // chat, not one per bubble that scrolls into view. Each bubble's chips
    // select only their own message's list.
    ref.watch(reactionsProvider.select((_) => null));
    // Who the "Seen by" pill and the readers card can name: the roster in a
    // group, the other member in a 1:1.
    final ReaderPeople people = {
      for (final m in roster)
        m.member.userId: (
          name: nameOrMember(
            AppLocalizations.of(context),
            m.member.displayName,
          ),
          avatarPath: m.member.avatarPath,
          slot: m.colorSlot,
        ),
      if (!isGroup && otherUserId != null)
        otherUserId: (
          name: nameOrMember(
            AppLocalizations.of(context),
            listed?.other?.displayName ?? title ?? '',
          ),
          avatarPath: listed?.other?.avatarPath,
          slot: null,
        ),
    };
    final timeline = ref.watch(chatTimelineProvider);
    final loadingOlder = ref.watch(olderLoadingProvider);
    final value = messages.value ?? const <Message>[];
    final messageIndexById = {
      for (var idx = 0; idx < (messages.value ?? const []).length; idx++)
        (messages.value ?? const [])[idx].id: idx,
    };
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
                  final system =
                      (ref.read(conversationListProvider).value ?? const [])
                          .where((c) => c.id == id)
                          .firstOrNull
                          ?.isSystem ==
                      true;
                  final page = system
                      ? SystemChatScreen(conversationId: id)
                      : isGroup
                      ? GroupScreen(
                          conversationId: id,
                          title:
                              title ?? AppLocalizations.of(context).commonGroup,
                        )
                      : otherUserId == null
                      ? null
                      // Already in this chat: no Message button on their page.
                      : PersonScreen(
                          userId: otherUserId,
                          fallbackName: title,
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
                          label:
                              title ??
                              AppLocalizations.of(context).commonConversation,
                          seed:
                              otherUserId ??
                              conversationId ??
                              title ??
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
                                title ??
                                    AppLocalizations.of(context)
                                        .commonConversation,
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
          // iPhone: the composer paints through the home-indicator area
          // itself (see _composerBottomInset), so no differently coloured
          // band is left under it. Android keeps the SafeArea as it was.
          bottom: !_isIos(context),
          child: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
                  child: ChatTextScale(
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        const Positioned.fill(child: ChatWallpaper()),
                        switch (messages) {
                          AsyncData() when timeline.isEmpty => Center(
                            child: Text(
                              AppLocalizations.of(context).messageEmpty,
                            ),
                          ),
                          _
                              when messages is! AsyncError &&
                                  timeline.isNotEmpty =>
                            ListView.builder(
                              controller: _scroll,
                              // Newest at the bottom, which is where the composer is.
                              reverse: true,
                              // Generous on purpose: a jump-to-hit needs the target
                              // bubble built even when it is far from the current
                              // scroll offset (see _scrollTo).
                              scrollCacheExtent: ScrollCacheExtent.pixels(2000),
                              // One extra row at the very top while an older page is
                              // being read.
                              itemCount:
                                  timeline.length + (loadingOlder ? 1 : 0),
                              itemBuilder: (context, i) {
                                if (i == timeline.length) {
                                  return const Padding(
                                    key: ValueKey('older-loading'),
                                    padding: EdgeInsets.symmetric(vertical: 12),
                                    child: Center(
                                      child: SisLoadingLogo(size: 24),
                                    ),
                                  );
                                }
                                final entry = timeline[timeline.length - 1 - i];
                                if (entry is EventEntry) {
                                  return GroupEventLine(
                                    entry.event,
                                    names: names,
                                    key: ValueKey('event-${entry.event.id}'),
                                  );
                                }
                                final message = (entry as MessageEntry).message;
                                if (isSystem) {
                                  return WhatsNewCard(
                                    key: _keyFor(message.id),
                                    body: message.body,
                                    time: previewTime(
                                      message.createdAt,
                                      DateTime.now(),
                                    ),
                                    isNewest:
                                        message.id == value.lastOrNull?.id,
                                  );
                                }
                                final index = messageIndexById[message.id] ?? 0;
                                final mine = me != null && message.isFrom(me);
                                final quoted = message.replyTo == null
                                    ? null
                                    : value
                                          .where((m) => m.id == message.replyTo)
                                          .firstOrNull;
                                final allowedActions = allowedMessageActions(
                                  message,
                                  me: me,
                                  now: DateTime.now(),
                                );
                                final bubble = SwipeableMessage(
                                  key: _keyFor(message.id),
                                  messageId: message.id,
                                  actions: allowedActions,
                                  onReply: () => runMessageAction(
                                    context,
                                    ref,
                                    message,
                                    MessageAction.reply,
                                  ),
                                  onAction: (action) => runMessageAction(
                                    context,
                                    ref,
                                    message,
                                    action,
                                  ),
                                  // A tap shows the "Seen by" pill and the reactions bar; a long press opens the action card. The system chat takes neither.
                                  onTap: isSystem
                                      ? null
                                      : () => ref
                                            .read(
                                              tappedMessageProvider.notifier,
                                            )
                                            .toggle(message.id),
                                  onLongPress: isSystem
                                      ? null
                                      : () => _openActionCard(
                                          message,
                                          mine: mine,
                                        ),
                                  child: Consumer(
                                    builder: (context, ref, _) {
                                      // Per-row watch: only a bubble whose own tick changed rebuilds.
                                      final delivery =
                                          mine && !message.isDeleted
                                          ? ref.watch(
                                              readMarksProvider.select(
                                                (a) => deliveryOf(
                                                  message,
                                                  a.value ?? const <ReadMark>[],
                                                ),
                                              ),
                                            )
                                          : null;
                                      final bubble = _Bubble(
                                        message,
                                        key: ValueKey('bubble-${message.id}'),
                                        mine: mine,
                                        delivery: delivery,
                                        sender:
                                            isGroup &&
                                                !mine &&
                                                startsRun(value, index)
                                            ? (names[message.senderId] ??
                                                  AppLocalizations.of(context)
                                                      .commonMember)
                                            : null,
                                        senderLeft: departedSenderIds.contains(
                                          message.senderId,
                                        ),
                                        senderSlot:
                                            slotByUser[message.senderId],
                                        quoted: quoted,
                                        quotedName: quoted == null
                                            ? null
                                            : quoted.senderId == me
                                            ? AppLocalizations.of(context)
                                                  .commonYou
                                            : (names[quoted.senderId] ??
                                                  AppLocalizations.of(context)
                                                      .commonMember),
                                        highlightQuery: searchQuery,
                                        isCurrentHit:
                                            message.id == currentHitId,
                                      );
                                      final tapped = ref.watch(
                                        tappedMessageProvider.select(
                                          (t) => t == message.id,
                                        ),
                                      );
                                      final reactable =
                                          !isSystem && message.canReact;
                                      // Always a Column, so the bubble keeps its state when the extras come and go.
                                      return Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          if (tapped &&
                                              mine &&
                                              !message.isDeleted)
                                            _SeenByPill(
                                              message: message,
                                              people: people,
                                            ),
                                          bubble,
                                          if (tapped && reactable)
                                            _ReactionsBar(
                                              messageId: message.id,
                                              mine: mine,
                                              onPick: (e) =>
                                                  _react(message.id, e),
                                            ),
                                        ],
                                      );
                                    },
                                  ),
                                );
                                return message.deletion ==
                                        MessageDeletion.vanished
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
                                failureReason(error),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                          _ => const Center(child: SisLoadingLogo()),
                        },
                        Positioned(
                          right: 12,
                          bottom: 12,
                          child: _JumpToLatest(
                            far: _far,
                            jumped: ref
                                .read(messagesProvider.notifier)
                                .isJumped,
                            onTap: _toLatest,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (isSystem) const UpToDateMark(),
              const _Composer(),
            ],
          ),
        ),
      ),
    );
  }
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
