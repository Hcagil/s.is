import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../domain/bot_command.dart';
import 'command_list_row.dart';

/// A panel that displays a list of bot commands filtered by the current input.
///
/// This widget listens to the provided [controller] and updates the displayed
/// commands based on the text value. It supports animated appearance and
/// scrolling.
class CommandListPanel extends StatelessWidget {
  /// Creates a [CommandListPanel].
  const CommandListPanel({
    super.key,
    required this.controller,
    required this.commands,
    required this.onPick,
  });

  /// The text editing controller used to observe the current input text.
  final TextEditingController controller;

  /// The full list of available bot commands to filter.
  final List<BotCommand> commands;

  /// Callback invoked when a command is picked, passing the command name
  /// followed by a space.
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, v, _) {
        final matches = matchCommands(commands, v.text);
        return AnimatedSize(
          duration: const Duration(milliseconds: 150),
          alignment: Alignment.bottomCenter,
          child: matches.isEmpty
              ? const SizedBox(width: double.infinity)
              : _Card(matches: matches, onPick: onPick),
        );
      },
    );
  }
}

/// Internal widget that renders the command list card with animations.
class _Card extends StatelessWidget {
  const _Card({required this.matches, required this.onPick});

  final List<BotCommand> matches;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, 6 * (1 - t)),
          child: child,
        ),
      ),
      child: Container(
        key: const ValueKey('command-list-panel'),
        margin: const EdgeInsets.fromLTRB(6, 0, 6, 8),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: SisBrand.of(context).surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: SisBrand.of(context).line),
        ),
        child: _buildCardContent(context),
      ),
    );
  }

  Widget _buildCardContent(BuildContext context) {
    final brand = SisBrand.of(context);
    final mq = MediaQuery.of(context);
    final maxH = math.min(196.0, (mq.size.height - mq.viewInsets.bottom) * 0.3);

    return Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxH),
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context)
              .copyWith(scrollbars: false, overscroll: false),
          child: ListView.separated(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const ClampingScrollPhysics(),
            itemCount: matches.length,
            separatorBuilder: (_, _) => Padding(
              padding: const EdgeInsets.only(left: 56, right: 12),
              child: Divider(height: 1, thickness: 1, color: brand.line),
            ),
            itemBuilder: (_, i) => CommandRow(
              command: matches[i],
              onTap: () => onPick('${matches[i].name} '),
            ),
          ),
        ),
      ),
    );
  }
}
