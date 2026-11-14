import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/notice.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/admin_drafts.dart';
import '../application/admin_panels_controller.dart';

class AdminTalkComposer extends ConsumerStatefulWidget {
  const AdminTalkComposer({super.key, this.conv});
  final String? conv;

  @override
  ConsumerState<AdminTalkComposer> createState() => _AdminTalkComposerState();
}

class _AdminTalkComposerState extends ConsumerState<AdminTalkComposer> {
  final _c = TextEditingController();
  bool _busy = false;
  late final _drafts = ref.read(adminDraftsProvider);
  late final _key = adminTalkDraftKey(widget.conv);
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) unawaited(_drafts.flush());
    });
    unawaited(
      _drafts.read(_key).then((t) {
        if (mounted && _c.text.isEmpty) _c.text = t;
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_drafts.flush());
    _focus.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    return Material(
      color: t.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('admin-talk-input'),
                  controller: _c,
                  focusNode: _focus,
                  onChanged: (t) => unawaited(_drafts.write(_key, t)),
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(adminDraftMax),
                  ],
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: l.adminTalkHint,
                    border: InputBorder.none,
                  ),
                ),
              ),
              IconButton(
                key: const ValueKey('admin-talk-send'),
                icon: const Icon(Icons.send_rounded),
                onPressed: _busy ? null : _send,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _send() async {
    final text = _c.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    final f = await ref
        .read(adminPanelsProvider.notifier)
        .sendTalk(text, conv: widget.conv);
    if (!mounted) return;
    setState(() => _busy = false);
    if (f == null) {
      _c.clear();
      unawaited(_drafts.remove(_key));
    } else {
      showSisNotice(
        context,
        AppLocalizations.of(context).adminSendFailed,
        isError: true,
      );
    }
  }
}
