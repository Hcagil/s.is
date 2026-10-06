import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/message.dart';

/// The in-chat search bar: replaces the conversation header's title/actions
/// while search is open. Back/close, the query field, an "n/m" (or "No
/// results") counter, and older/newer buttons.
class ChatSearchBar extends ConsumerStatefulWidget {
  const ChatSearchBar({
    super.key,
    required this.initialQuery,
    required this.onClose,
  });

  /// Pre-filled and searched immediately when non-empty -- opening search
  /// already primed with a query, e.g. from the chat list's own search.
  final String? initialQuery;

  /// The member tapped close/back. The caller closes the search controller
  /// and returns the header to normal; this widget only reports the tap.
  final VoidCallback onClose;

  @override
  ConsumerState<ChatSearchBar> createState() => _ChatSearchBarState();
}

class _ChatSearchBarState extends ConsumerState<ChatSearchBar> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialQuery ?? '',
  );

  @override
  void initState() {
    super.initState();
    final initial = widget.initialQuery;
    if (initial != null && initial.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _search(initial));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    final result = await ref.read(chatSearchProvider.notifier).search(query);
    if (result case Err(:final failure) when mounted) {
      showSisNotice(context, failure.message, isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatSearchProvider);
    ref.listen(chatSearchProvider.select((s) => s.failure), (previous, next) {
      if (next != null) showSisNotice(context, next.message, isError: true);
    });
    return Row(
      children: [
        IconButton(
          key: const ValueKey('chat-search-close'),
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onClose,
        ),
        Expanded(
          child: TextField(
            key: const ValueKey('chat-search-field'),
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              hintText: AppLocalizations.of(context).searchInChat,
              border: InputBorder.none,
            ),
            onChanged: (text) => unawaited(_search(text)),
          ),
        ),
        if (isSearchable(state.query))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              state.hits.isEmpty
                  ? (state.serverAnswered
                        ? AppLocalizations.of(context).searchNoResults
                        : '')
                  : '${state.index + 1}/${state.hits.length}${state.serverAnswered ? '' : '+'}',
              key: const ValueKey('chat-search-count'),
            ),
          ),
        IconButton(
          key: const ValueKey('chat-search-older'),
          icon: const Icon(Icons.keyboard_arrow_up),
          onPressed: state.hits.isEmpty
              ? null
              : () => ref.read(chatSearchProvider.notifier).next(),
        ),
        IconButton(
          key: const ValueKey('chat-search-newer'),
          icon: const Icon(Icons.keyboard_arrow_down),
          onPressed: state.hits.isEmpty
              ? null
              : () => ref.read(chatSearchProvider.notifier).previous(),
        ),
      ],
    );
  }
}
