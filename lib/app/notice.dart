import 'package:flutter/material.dart';

import 'theme.dart';

/// A floating pill under the header: the one way SIS reports a result of
/// something the member just did (replaces every SnackBar). Announced to
/// screen readers via [Semantics.liveRegion]; dismisses itself.
class SisNotice extends StatelessWidget {
  const SisNotice({super.key, required this.message, required this.isError});

  final String message;
  final bool isError;

  static const _duration = Duration(seconds: 2);

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    return Semantics(
      liveRegion: true,
      label: message,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 18, 8),
          decoration: BoxDecoration(
            color: t.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: t.line),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: .12),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isError ? t.danger : null,
                  gradient: isError ? null : t.gradient,
                ),
                child: Icon(
                  isError ? Icons.priority_high_rounded : Icons.check_rounded,
                  color: Colors.white,
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows [message] as a [SisNotice] under the header for ~2 s. The one way
/// to show a notice; do not call ScaffoldMessenger/SnackBar directly.
void showSisNotice(
  BuildContext context,
  String message, {
  bool isError = false,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => Positioned(
      top: MediaQuery.paddingOf(context).top + 64,
      left: 24,
      right: 24,
      child: Center(
        child: SisNotice(message: message, isError: isError),
      ),
    ),
  );
  overlay.insert(entry);
  Future.delayed(SisNotice._duration, () {
    if (entry.mounted) entry.remove();
  });
}
