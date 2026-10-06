part of 'message_screen.dart';

/// The small floating circle above the composer that takes the member back to
/// the newest message. Shown when the newest message is more than a screen
/// away, or the list is a jumped (search) window.
class _JumpToLatest extends StatelessWidget {
  const _JumpToLatest({
    required this.far,
    required this.jumped,
    required this.onTap,
  });

  final ValueNotifier<bool> far;
  final bool jumped;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: far,
      builder: (context, isFar, _) {
        final show = isFar || jumped;
        return IgnorePointer(
          ignoring: !show,
          child: AnimatedScale(
            scale: show ? 1 : 0.6,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              opacity: show ? 1 : 0,
              duration: const Duration(milliseconds: 140),
              child: Material(
                key: const ValueKey('jump-to-latest'),
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                elevation: 3,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onTap,
                  child: const SizedBox(
                    width: 44,
                    height: 44,
                    child: Icon(Icons.keyboard_arrow_down, size: 28),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
