import 'package:flutter/material.dart';

import '../../../app/controls.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/poll.dart';

class PollCreatePage extends StatefulWidget {
  const PollCreatePage({super.key});

  @override
  State<PollCreatePage> createState() => _PollCreatePageState();
}

class _PollCreatePageState extends State<PollCreatePage> {
  final _question = TextEditingController();
  final _options = [_Opt(), _Opt()];
  bool _multiple = false;
  bool _anonymous = false;
  bool _sent = false;

  @override
  void dispose() {
    _question.dispose();
    for (final opt in _options) {
      opt.controller.dispose();
    }
    super.dispose();
  }

  bool get _ready =>
      isSendablePoll(_question.text, _options.map((o) => o.controller.text));

  bool get _dirty =>
      _question.text.trim().isNotEmpty ||
      _options.any((opt) => opt.controller.text.trim().isNotEmpty);

  Future<bool?> _confirmDiscard() {
    final l = AppLocalizations.of(context);
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.pollDiscardTitle),
        content: Text(l.pollDiscardBody),
        actions: [
          TextButton(
            key: const ValueKey('poll-discard-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.pollDiscardCancel),
          ),
          TextButton(
            key: const ValueKey('poll-discard-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.pollDiscardConfirm),
          ),
        ],
      ),
    );
  }

  void _send() {
    if (_sent) return;
    setState(() => _sent = true);
    Navigator.of(context).pop(
      PollDraft(
        question: _question.text.trim(),
        options: cleanPollOptions(_options.map((o) => o.controller.text)),
        multiple: _multiple,
        anonymous: _anonymous,
      ),
    );
  }

  Widget _box(Widget child) => Container(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    margin: const EdgeInsets.only(bottom: 12),
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _sent || !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final leave = await _confirmDiscard();
        if (leave == true && context.mounted) Navigator.of(context).pop();
      },
      child: Scaffold(
        appBar: AppBar(title: Text(l.pollNewTitle)),
        body: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  _box(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.pollQuestionLabel.toUpperCase(),
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        TextField(
                          key: const ValueKey('poll-question'),
                          controller: _question,
                          maxLength: pollMaxQuestionLength,
                          minLines: 1,
                          maxLines: 4,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: InputDecoration(
                            hintText: l.pollQuestionHint,
                            border: InputBorder.none,
                            counterText: '',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ],
                    ),
                  ),
                  _box(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.pollOptionsLabel.toUpperCase(),
                          style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        ReorderableListView(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          buildDefaultDragHandles: false,
                          onReorderItem: (oldIndex, newIndex) {
                            setState(() {
                              final item = _options.removeAt(oldIndex);
                              _options.insert(newIndex, item);
                            });
                          },
                          children: [
                            for (var i = 0; i < _options.length; i++)
                              Row(
                                key: _options[i].key,
                                children: [
                                  ReorderableDragStartListener(
                                    index: i,
                                    child: const Icon(Icons.drag_handle),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: TextField(
                                      key: ValueKey('poll-option-$i'),
                                      controller: _options[i].controller,
                                      maxLength: pollMaxOptionLength,
                                      decoration: InputDecoration(
                                        hintText: l.pollOptionHint,
                                        border: InputBorder.none,
                                        counterText: '',
                                      ),
                                      onChanged: (_) => setState(() {}),
                                    ),
                                  ),
                                  if (_options.length > pollMinOptions)
                                    IconButton(
                                      key: ValueKey('poll-option-remove-$i'),
                                      icon: const Icon(Icons.close),
                                      onPressed: () =>
                                          setState(() => _options.removeAt(i)),
                                    ),
                                ],
                              ),
                          ],
                        ),
                        if (_options.length < pollMaxOptions)
                          InkWell(
                            key: const ValueKey('poll-add-option'),
                            onTap: () => setState(() => _options.add(_Opt())),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    radius: 13,
                                    backgroundColor: scheme.primary,
                                    child: Icon(
                                      Icons.add,
                                      size: 16,
                                      color: scheme.onPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    l.pollAddOption,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: scheme.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Text(
                              l.pollOptionsMax,
                              style: TextStyle(
                                fontSize: 13,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  _box(
                    Column(
                      children: [
                        SisSwitchTile(
                          key: const ValueKey('poll-multiple'),
                          title: l.pollMultipleTitle,
                          value: _multiple,
                          onChanged: (v) => setState(() => _multiple = v),
                        ),
                        SisSwitchTile(
                          key: const ValueKey('poll-anonymous'),
                          title: l.pollAnonymousTitle,
                          subtitle: l.pollAnonymousSubtitle,
                          value: _anonymous,
                          onChanged: (v) => setState(() => _anonymous = v),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('poll-send'),
                  onPressed: _ready ? _send : null,
                  child: Text(l.pollSend),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Opt {
  final key = UniqueKey();
  final controller = TextEditingController();
}
