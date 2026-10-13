import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import 'sticker_draft.dart';
import 'sticker_maker_widgets.dart';

/// The text step: type, colour, font, size, and drag to place.
class StickerTextPage extends StatefulWidget {
  /// Creates the text step for [draft]; it edits the last text, or adds one.
  const StickerTextPage({super.key, required this.draft});

  /// The sticker being made.
  final StickerDraft draft;

  @override
  State<StickerTextPage> createState() => _StickerTextPageState();
}

class _StickerTextPageState extends State<StickerTextPage> {
  late final MakerText _t;
  late final bool _created;
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    if (widget.draft.texts.isEmpty) {
      _t = MakerText();
      widget.draft.texts.add(_t);
      _created = true;
    } else {
      _t = widget.draft.texts.last;
      _created = false;
    }
    _controller = TextEditingController(text: _t.text);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final d = widget.draft;
    return Scaffold(
      key: const ValueKey('sticker-text-page'),
      appBar: AppBar(
        leading: IconButton(
          key: const ValueKey('maker-cancel'),
          icon: const Icon(Icons.close),
          onPressed: _cancel,
        ),
        title: Text(l.makerTextTitle),
        actions: [
          IconButton(
            key: const ValueKey('maker-delete'),
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
          IconButton(
            key: const ValueKey('maker-ok'),
            icon: const Icon(Icons.check),
            onPressed: _ok,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: d,
        builder: (context, child) {
          return Column(
            children: [
              MakerPreview(
                draft: d,
                cut: d.cutOut && d.hasCutOut ? 1 : 0,
                onStart: _move,
                onUpdate: _move,
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      TextField(
                        key: const ValueKey('maker-text-field'),
                        controller: _controller,
                        decoration: InputDecoration(hintText: l.makerTextHint),
                        onChanged: (v) {
                          _t.text = v;
                          d.changed();
                        },
                      ),
                      const SizedBox(height: 12),
                      MakerSwatches(
                        selected: _t.colour,
                        onPick: (c) {
                          _t.colour = c;
                          d.changed();
                        },
                      ),
                      const SizedBox(height: 12),
                      MakerSegments(
                        keyPrefix: 'maker-font',
                        labels: [
                          l.makerFontSans,
                          l.makerFontSerif,
                          l.makerFontHand,
                        ],
                        selected: _t.font.index,
                        onChanged: (i) {
                          _t.font = MakerFont.values[i];
                          d.changed();
                        },
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Text(l.makerSize),
                          Expanded(
                            child: Slider(
                              key: const ValueKey('maker-size'),
                              min: 12,
                              max: 40,
                              value: _t.size,
                              onChanged: (v) {
                                _t.size = v;
                                d.changed();
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _move(Offset p) {
    _t.position = p;
    widget.draft.changed();
  }

  void _cancel() {
    if (_created) {
      widget.draft.removeText(_t);
    }
    Navigator.of(context).pop();
  }

  void _delete() {
    widget.draft.removeText(_t);
    Navigator.of(context).pop();
  }

  void _ok() {
    if (_t.text.trim().isEmpty) {
      widget.draft.removeText(_t);
    }
    Navigator.of(context).pop();
  }
}
