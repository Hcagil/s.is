import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr/qr.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../crypto/domain/security_code.dart';
import '../application/security_code_controller.dart';

Future<void> showSecurityCodePage(
  BuildContext context, {
  required String peerUserId,
  required String name,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => SecurityCodePage(peerUserId: peerUserId, name: name),
  ),
);

class SecurityCodePage extends ConsumerWidget {
  const SecurityCodePage({
    super.key,
    required this.peerUserId,
    required this.name,
  });
  final String peerUserId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(securityCodeProvider(peerUserId)).value;
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: t.background,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.securityCodeTitle),
            Text(name, style: text.bodySmall?.copyWith(color: t.muted)),
          ],
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Center(
          child: Column(
            children: [
              if (state is SecurityCodeUnavailable)
                Text(
                  l.securityCodeUnavailable(name),
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: t.muted),
                ),
              if (state is SecurityCodeReady) ...[
                _QrBox(state.digits),
                const SizedBox(height: 24),
                Column(
                  key: const ValueKey('security-code-digits'),
                  children: [
                    for (final line in securityCodeLines(state.digits))
                      SelectableText(
                        line,
                        textAlign: TextAlign.center,
                        style: text.bodyLarge?.copyWith(
                          color: t.text,
                          letterSpacing: 1.5,
                          height: 1.6,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                if (state.verified)
                  _VerifiedBlock(peerUserId: peerUserId, name: name)
                else
                  _VerifyButtons(
                    peerUserId: peerUserId,
                    name: name,
                    digits: state.digits,
                  ),
                const SizedBox(height: 24),
                Text(
                  l.securityCodeIntro(name),
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(color: t.muted),
                ),
                const SizedBox(height: 12),
                Text(
                  l.securityCodeNewPhoneNote(name),
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(color: t.muted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _QrBox extends StatelessWidget {
  const _QrBox(this.data);

  final String data;

  @override
  Widget build(BuildContext context) {
    // A scanner needs dark modules on white, so white in dark mode too.
    return Container(
      width: 220,
      height: 220,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
      ),
      child: CustomPaint(painter: _QrPainter(data)),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(String data)
    : _image = QrImage(
        QrCode(
          payload: QrPayload.fromString(data),
          errorCorrectLevel: QrErrorCorrectLevel.medium,
        ),
      );

  final QrImage _image;

  @override
  void paint(Canvas canvas, Size size) {
    final n = _image.moduleCount;
    final cell = size.width / n;
    final paint = Paint()..color = Colors.black;
    for (var row = 0; row < n; row++) {
      for (var col = 0; col < n; col++) {
        if (_image.isDark(row, col)) {
          canvas.drawRect(
            Rect.fromLTWH(col * cell, row * cell, cell + 0.5, cell + 0.5),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => false;
}

class _VerifyButtons extends ConsumerWidget {
  const _VerifyButtons({
    required this.peerUserId,
    required this.name,
    required this.digits,
  });

  final String peerUserId;
  final String name;

  /// The code the person is looking at; marking only succeeds if it is still the current code.
  final String digits;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return Row(
      key: const ValueKey('security-code-buttons'),
      children: [
        Expanded(
          child: FilledButton(
            key: const ValueKey('security-code-matches'),
            onPressed: () => ref
                .read(securityCodeActionsProvider)
                .markVerified(peerUserId, digits),
            child: Text(l.securityCodeMatches),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: OutlinedButton(
            key: const ValueKey('security-code-differs'),
            onPressed: () => _showMismatch(context, name),
            child: Text(l.securityCodeDiffers),
          ),
        ),
      ],
    );
  }
}

class _VerifiedBlock extends ConsumerWidget {
  const _VerifiedBlock({required this.peerUserId, required this.name});

  final String peerUserId;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final text = Theme.of(context).textTheme;
    return Column(
      key: const ValueKey('security-code-verified'),
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.verified_user_rounded, size: 20, color: t.brand),
            const SizedBox(width: 8),
            Text(
              l.securityCodeVerified,
              style: text.titleMedium?.copyWith(color: t.text),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          l.securityCodeVerifiedNote(name),
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: t.muted),
        ),
        TextButton(
          key: const ValueKey('security-code-unverify'),
          onPressed: () =>
              ref.read(securityCodeActionsProvider).unmarkVerified(peerUserId),
          child: Text(l.securityCodeUnverify),
        ),
      ],
    );
  }
}

Future<void> _showMismatch(BuildContext context, String name) {
  final l = AppLocalizations.of(context);
  final t = SisBrand.of(context);
  final text = Theme.of(context).textTheme;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          key: const ValueKey('security-code-mismatch-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l.securityCodeMismatchTitle, style: text.titleMedium),
            const SizedBox(height: 12),
            Text(
              l.securityCodeMismatchBody(name),
              style: text.bodyMedium?.copyWith(color: t.muted),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(l.securityCodeOk),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
