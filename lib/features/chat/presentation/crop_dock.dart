import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../app/theme.dart';

/// A widget that provides a press effect with scaling and animation.
class CropPress extends StatefulWidget {
  /// Creates a new [CropPress].
  const CropPress({super.key, required this.onTap, required this.child});

  /// The callback that is called when the widget is tapped.
  final VoidCallback? onTap;

  /// The widget below this widget in the tree.
  final Widget child;

  @override
  State<CropPress> createState() => _CropPressState();
}

class _CropPressState extends State<CropPress> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: widget.child,
      ),
    );
  }
}

/// Bottom action row: Cancel, rotate with Reset, Done.
class CropActionRow extends StatelessWidget {
  /// Creates a new [CropActionRow].
  const CropActionRow({
    super.key,
    required this.cancelLabel,
    required this.doneLabel,
    required this.resetLabel,
    required this.rotateLabel,
    required this.changed,
    required this.canDone,
    required this.onCancel,
    required this.onDone,
    required this.onRotate,
    required this.onReset,
  });

  /// The label for the cancel button.
  final String cancelLabel;

  /// The label for the done button.
  final String doneLabel;

  /// The label for the reset button.
  final String resetLabel;

  /// The label for the rotate button.
  final String rotateLabel;

  /// Whether the image has been changed.
  final bool changed;

  /// Whether the done button is enabled.
  final bool canDone;

  /// Called when the cancel button is pressed.
  final VoidCallback onCancel;

  /// Called when the done button is pressed.
  final VoidCallback onDone;

  /// Called when the rotate button is pressed.
  final VoidCallback onRotate;

  /// Called when the reset button is pressed.
  final VoidCallback onReset;

  /// Reset text: shown only when changed, to the right of the centred rotate button.
  Widget _reset(SisBrand brand) => AnimatedOpacity(
    opacity: changed ? 1 : 0,
    duration: const Duration(milliseconds: 150),
    child: IgnorePointer(
      ignoring: !changed,
      child: TextButton(
        key: const ValueKey('crop-free-reset'),
        onPressed: onReset,
        style: TextButton.styleFrom(
          foregroundColor: brand.brand,
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 8),
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            resetLabel,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    return SizedBox(
      height: 64,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  key: const ValueKey('crop-free-cancel'),
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    foregroundColor: brand.muted,
                    minimumSize: const Size(48, 48),
                  ),
                  child: Text(
                    cancelLabel,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            Semantics(
              button: true,
              label: rotateLabel,
              child: CropPress(
                onTap: onRotate,
                child: Container(
                  key: const ValueKey('crop-free-rotate'),
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: brand.surfaceHigh,
                  ),
                  child: Icon(
                    Icons.rotate_90_degrees_ccw_outlined,
                    color: brand.text,
                    size: 24,
                  ),
                ),
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    // Reset keeps >= 48 dp and up to 16 dp air on each side.
                    child: LayoutBuilder(
                      builder: (context, c) => Center(
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: math.max(48, c.maxWidth - 32),
                          ),
                          child: _reset(brand),
                        ),
                      ),
                    ),
                  ),
                  CropPress(
                    onTap: canDone ? onDone : null,
                    child: Container(
                      key: const ValueKey('crop-free-done'),
                      height: 44,
                      width: 72,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: brand.brand,
                        borderRadius: BorderRadius.circular(22),
                      ),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Text(
                          doneLabel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bottom dock: own area with a hairline on top, not a panel.
class CropDock extends StatelessWidget {
  /// Creates a new [CropDock].
  const CropDock({super.key, required this.children});

  /// The rows to display in the dock.
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: brand.background,
        border: Border(top: BorderSide(color: brand.line)),
      ),
      child: SafeArea(
        top: false,
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }
}

/// A row of crop chips that can be selected.
class CropChipRow extends StatelessWidget {
  /// Creates a new [CropChipRow].
  const CropChipRow({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelect,
  });

  /// The labels for the chips.
  final List<String> labels;

  /// The index of the selected chip.
  final int selected;

  /// Called when a chip is selected.
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    return SizedBox(
      height: 56,
      child: Stack(
        children: [
          Positioned.fill(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: labels.length,
              separatorBuilder: (context, index) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final on = i == selected;
                return Center(
                  child: CropPress(
                    onTap: () => onSelect(i),
                    child: AnimatedContainer(
                      key: ValueKey('crop-chip-$i'),
                      duration: const Duration(milliseconds: 150),
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: on ? brand.brand : brand.surfaceHigh,
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Text(
                        labels[i],
                        style: TextStyle(
                          color: on ? Colors.white : brand.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: 24,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      brand.background.withValues(alpha: 0),
                      brand.background,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
