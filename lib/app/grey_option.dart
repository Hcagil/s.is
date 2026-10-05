import 'package:flutter/material.dart';

import 'theme.dart';

/// Wraps any row, switch, button or tile as an option that exists in the
/// design but not yet in the app: a disabled look, no handler (taps are
/// swallowed), not focusable, and semantics that say disabled.
///
/// It never adds a text label (no "soon", no "yakında"): the grey look is the
/// whole message. The key is `grey-<name>`.
class GreyOption extends StatelessWidget {
  GreyOption({required String name, this.label, required this.child})
    : super(key: ValueKey('grey-$name'));

  /// What a screen reader says for the row (the child's own semantics are
  /// dropped so its tap action cannot be reached). Pass the localised name.
  final String? label;
  final Widget child;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    enabled: false,
    label: label,
    child: ExcludeSemantics(
      child: Opacity(
        opacity: SisTokens.greyOpacity,
        child: ExcludeFocus(child: IgnorePointer(child: child)),
      ),
    ),
  );
}
