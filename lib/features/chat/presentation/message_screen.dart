import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import '../domain/links.dart';
import '../domain/message.dart';
import '../domain/read_marks.dart';
import 'attachment_sheet.dart';
import 'conversation_list.dart';
import 'message_actions.dart';
import 'photo_viewer.dart';
import 'profile_pages.dart';

/// Opens [conversationId] and closes it again when the screen is popped, so
/// the Realtime subscription lives exactly as long as the screen does.
Future<void> openConversation(
  BuildContext context,
  WidgetRef ref,
  String conversationId, {
  String? title,
  String? otherUserId,
  bool group = false,
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
      builder: (_) =>
          MessageScreen(title: title, otherUserId: otherUserId, group: group),
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
class MessageScreen extends ConsumerWidget {
  const MessageScreen({
    super.key,
    this.title,
    this.otherUserId,
    this.group = false,
  });

  final String? title;

  /// A group names each sender above their run of messages.
  final bool group;

  /// The other member of a 1:1, whose online status the header shows. Null
  /// for a group, where the header shows only who is typing.
  final String? otherUserId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
    final status = _status(ref, otherUserId);
    final names = group
        ? {
            for (final m in ref.watch(membersProvider).value ?? const [])
              m.userId: m.displayName,
          }
        : const <String, String>{};
    // Read status, where it is shared: your own messages look a little grey
    // until every sharing member has read them.
    final marks = ref.watch(readMarksProvider).value ?? const <ReadMark>[];
    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          key: const ValueKey('conversation-title'),
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            final id = ref.read(openConversationProvider);
            if (id == null) return;
            final page = group
                ? GroupScreen(conversationId: id, title: title ?? 'Group')
                : otherUserId == null
                ? null
                // Already in this chat: no Message button on their page.
                : PersonScreen(
                    userId: otherUserId!,
                    fallbackName: title,
                    showMessage: false,
                  );
            if (page == null) return;
            Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => page));
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title ?? 'Conversation'),
              if (status != null)
                Text(
                  status,
                  key: const ValueKey('conversation-status'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
      body: SisGlow(
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: switch (messages) {
                  AsyncData(:final value) when value.isEmpty => const Center(
                    child: Text('No messages yet. Say something.'),
                  ),
                  AsyncData(:final value) => ListView.builder(
                    // Newest at the bottom, which is where the composer is.
                    reverse: true,
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
                      final bubble = GestureDetector(
                        onLongPress: () => showMessageActions(
                          context,
                          ref,
                          message,
                          me: me,
                          group: group,
                        ),
                        child: _Bubble(
                          message,
                          key: ValueKey('read-$unread-${message.id}'),
                          mine: mine,
                          unread: unread,
                          sender: group && !mine && startsRun(value, index)
                              ? (names[message.senderId] ?? 'Member')
                              : null,
                          quoted: quoted,
                          quotedName: quoted == null
                              ? null
                              : quoted.senderId == me
                              ? 'You'
                              : (names[quoted.senderId] ?? 'Member'),
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
                      child: Text(reasonOf(error), textAlign: TextAlign.center),
                    ),
                  ),
                  _ => const Center(child: SisLoadingLogo()),
                },
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

  // The bubble's own outer cap and the two insets that eat into it: 12 px
  // padding, plus -- for a "mine" bubble only -- a 1.5 px border that is
  // always laid out (even transparent, when read). _BodyWithTime measures
  // its fits-inline decision against [_contentWidth], not a copy of these
  // numbers, so the two cannot drift apart.
  static const _maxWidth = 320.0;
  static const _hPad = 12.0;
  static const _borderWidth = 1.5;

  double get _contentWidth =>
      _maxWidth - 2 * _hPad - (mine ? 2 * _borderWidth : 0);

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
          border: mine
              ? Border.all(
                  width: _borderWidth,
                  color: unread ? brand.unreadEdge : Colors.transparent,
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
                _IgnoreIntrinsicWidth(
                  child: Padding(
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
                ),
              if (message.replyTo != null && !message.isDeleted)
                _IgnoreIntrinsicWidth(
                  child: Container(
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
                ),
              if (sender != null)
                _IgnoreIntrinsicWidth(
                  child: Padding(
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
/// widget test finds each with `find.text()`.
class _BodyWithTime extends StatelessWidget {
  const _BodyWithTime({
    required this.message,
    required this.bodyStyle,
    required this.linkColor,
    required this.maxContentWidth,
    required this.topPadding,
    required this.timeText,
    required this.timeStyle,
  });

  final Message message;
  final TextStyle bodyStyle;
  final Color linkColor;

  /// The bubble's real content column: its outer cap minus padding and,
  /// for a "mine" bubble, its always-laid-out border. Passed down from
  /// [_Bubble], which is the one place that inset is defined, so this
  /// widget never keeps its own copy of that arithmetic to drift from it.
  final double maxContentWidth;
  final double topPadding;
  final String timeText;
  final TextStyle timeStyle;

  static const _gap = 6.0;

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
    final timePainter = TextPainter(
      text: TextSpan(text: timeText, style: defaultStyle.merge(timeStyle)),
      textDirection: direction,
      textScaler: scaler,
    )..layout();
    final timeWidth = timePainter.width;
    bodyPainter.dispose();
    timePainter.dispose();

    // ponytail: RTL always drops to the own-row layout below, never inline.
    // The fits math above assumes a line's trailing edge is the column's
    // right edge (true for LTR); measuring an RTL line's *visual* end would
    // need glyph-level box positions, not just a summed width. Upgrade path:
    // measure with getBoxesForSelection (as the qa Measured helper does) if
    // RTL locales ever ship.
    final fits =
        direction != TextDirection.rtl &&
        lastLineWidth + _gap + timeWidth <= maxContentWidth;

    final timeWidget = Text(
      timeText,
      key: ValueKey('time-${message.id}'),
      style: timeStyle,
    );

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

/// Only the body (and an attachment) should ever decide how wide a bubble
/// hugs to; a reply's quote preview can hold a whole message and must not
/// itself win that decision. This makes its child invisible to an ancestor
/// `IntrinsicWidth`'s hug query (reporting no width need of its own) while
/// leaving its real layout untouched: it is handed whatever width the
/// bubble actually settles on -- driven by body/attachment -- and wraps
/// (up to its own `maxLines`) inside that, same as any ordinary child.
class _IgnoreIntrinsicWidth extends SingleChildRenderObjectWidget {
  const _IgnoreIntrinsicWidth({required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderIgnoreIntrinsicWidth();
}

class _RenderIgnoreIntrinsicWidth extends RenderProxyBox {
  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;
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
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final body = _controller.text;
    final editing = ref.read(editingProvider);
    // The same rule the database enforces, applied before the round trip. A
    // photo message's caption may be empty; a text-only message may not.
    final bodyOk = editing != null && editing.hasAttachment
        ? body.trim().length <= maxMessageLength
        : isSendableBody(body);
    if (_sending || !bodyOk) return;
    setState(() => _sending = true);
    final result = editing == null
        ? await ref.read(messagesProvider.notifier).send(body)
        : await ref.read(messagesProvider.notifier).editMessage(editing, body);
    if (!mounted) return;
    setState(() => _sending = false);
    switch (result) {
      case Ok():
        // Cleared only on success, so nothing a member typed is lost.
        _controller.clear();
        if (editing != null) ref.read(editingProvider.notifier).clear();
      case Err(:final failure):
        showSisNotice(context, failure.message, isError: true);
    }
  }

  /// Picks and sends an image, with whatever is typed as its caption.
  Future<void> _attach() async {
    if (_sending) return;
    // The phone's own photos. Closing the sheet without choosing one sends
    // nothing.
    final image = await showAttachmentSheet(context);
    if (image == null || !mounted) return;
    setState(() => _sending = true);
    final result = await ref
        .read(messagesProvider.notifier)
        .sendImage(body: _controller.text, chosen: image);
    if (!mounted) return;
    setState(() => _sending = false);
    // null means the member backed out of the picker: not a failure.
    switch (result) {
      case null:
        return;
      case Ok():
        _controller.clear();
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
  });

  final String text;
  final TextStyle style;
  final Color linkColor;

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

  @override
  Widget build(BuildContext context) {
    _clear();
    final segments = linkSegments(widget.text);
    if (segments.every((s) => s.link == null)) {
      return Text(widget.text, style: widget.style);
    }
    final spans = <TextSpan>[];
    for (final s in segments) {
      final link = s.link;
      if (link == null) {
        spans.add(TextSpan(text: s.text));
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
