import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../../crypto/domain/security_code.dart';
import '../application/admin_panels_controller.dart';
import '../domain/admin_panels_repository.dart';

class AdminLinkView extends ConsumerStatefulWidget {
  const AdminLinkView({super.key});

  @override
  ConsumerState<AdminLinkView> createState() => _AdminLinkViewState();
}

class _AdminLinkViewState extends ConsumerState<AdminLinkView> {
  bool _started = false;
  String? _firstCode;
  bool _codeChanged = false;

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(adminPanelsProvider);
    final status = s.link;
    final phase = status?.phase;
    final code = status?.code;
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    final text = Theme.of(context).textTheme;

    if (phase == AdminLinkPhase.unlinked &&
        !s.linkBusy &&
        s.failure == null &&
        !_started) {
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(adminPanelsProvider.notifier).startLink();
        }
      });
    }

    if (code != null) {
      if (_firstCode == null) {
        _firstCode = code;
      } else if (_firstCode != code) {
        _codeChanged = true;
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
      child: Center(
        child: Column(
          children: [
            Text(l.adminLinkTitle, style: text.titleLarge),
            const SizedBox(height: 24),
            if (code != null) ...[
              if (_codeChanged || phase == AdminLinkPhase.changed)
                Text(
                  l.adminLinkCodeChanged,
                  key: const ValueKey('admin-link-changed'),
                  style: text.bodyMedium?.copyWith(color: t.text),
                ),
              Column(
                key: const ValueKey('admin-link-code'),
                children: [
                  for (final line in securityCodeLines(code))
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
              Text(
                l.adminLinkBody,
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: t.muted),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('admin-link-matches'),
                  onPressed: s.linkBusy
                      ? null
                      : () => ref
                            .read(adminPanelsProvider.notifier)
                            .confirmLink(),
                  child: Text(l.adminLinkButton),
                ),
              ),
            ] else if (phase == AdminLinkPhase.waiting || s.linkBusy) ...[
              Text(
                l.adminLinkStatusWorking,
                style: text.bodyMedium?.copyWith(color: t.muted),
              ),
            ] else ...[
              Text(
                l.adminLinkStatusIdle,
                style: text.bodyMedium?.copyWith(color: t.muted),
              ),
            ],
            if (s.failure != null) ...[
              const SizedBox(height: 24),
              Text(
                l.adminLinkStatusFailed,
                key: const ValueKey('admin-link-failed'),
                style: text.bodyMedium?.copyWith(color: t.text),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  key: const ValueKey('admin-link-retry'),
                  onPressed: () =>
                      ref.read(adminPanelsProvider.notifier).startLink(),
                  child: Text(l.adminRetry),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
