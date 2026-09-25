import 'package:flutter/material.dart';

import 'theme.dart';

/// A toggle with a brand-gradient track when on (replaces Switch/
/// SwitchListTile's switch). Keeps the toggle semantics a screen reader
/// expects.
class SisSwitch extends StatelessWidget {
  const SisSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    return MergeSemantics(
      child: Semantics(
        toggled: value,
        enabled: onChanged != null,
        child: GestureDetector(
          onTap: onChanged == null ? null : () => onChanged!(!value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 52,
            height: 30,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(999),
              gradient: value ? t.gradient : null,
              color: value ? null : t.surfaceHigh,
            ),
            child: AnimatedAlign(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: value ? Colors.white : t.muted,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A settings row with a [SisSwitch] trailing (replaces SwitchListTile).
/// Tapping anywhere on the row toggles it, like SwitchListTile did.
class SisSwitchTile extends StatelessWidget {
  const SisSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      toggled: value,
      child: ListTile(
        title: Text(title),
        subtitle: subtitle == null ? null : Text(subtitle!),
        // The switch's own toggled/tap semantics would otherwise sit on a
        // second, unlabelled node; the row above is the one node a screen
        // reader should land on, the way SwitchListTile's did.
        trailing: ExcludeSemantics(
          child: SisSwitch(value: value, onChanged: onChanged),
        ),
        onTap: () => onChanged(!value),
      ),
    ),
  );
}

/// One option of a single-choice list (replaces RadioListTile/RadioGroup):
/// a card with a brand outline and filled check when selected, an empty
/// ring when not.
class SisChoiceCard<T> extends StatelessWidget {
  const SisChoiceCard({
    super.key,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    required this.title,
    this.subtitle,
  });

  final T value;
  final T groupValue;
  final ValueChanged<T> onChanged;
  final String title;
  final String? subtitle;

  bool get _selected => value == groupValue;

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    return Semantics(
      inMutuallyExclusiveGroup: true,
      selected: _selected,
      button: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onChanged(value),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: t.surface,
                border: Border.all(
                  color: _selected ? t.brand : t.line,
                  width: _selected ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(subtitle!, style: TextStyle(color: t.muted)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (_selected)
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: t.gradient,
                      ),
                      child: const Icon(
                        Icons.check_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    )
                  else
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: t.line, width: 1.5),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
