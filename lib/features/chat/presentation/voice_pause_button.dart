import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import 'voice_icons.dart';

/// The round button above the send disc while a recording is locked: pause,
/// and once paused a mic to resume. The visual is 40 dp, the tap area 48 dp.
class VoicePauseButton extends StatelessWidget {
  /// Creates the button.
  const VoicePauseButton({
    super.key,
    required this.paused,
    required this.onTap,
  });

  /// Whether the recording is held now.
  final bool paused;

  /// Called on a tap.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brand = SisBrand.of(context);
    final l = AppLocalizations.of(context);
    return Semantics(
      button: true,
      label: paused ? l.voiceResumeRecording : l.voicePauseRecording,
      child: GestureDetector(
        key: const ValueKey('voice-pause-button'),
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: brand.surface,
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x33000000),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: SizedBox(
                width: 40,
                height: 40,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: paused
                      ? VoiceGlyph(
                          key: const ValueKey('voice-resume-icon'),
                          kind: VoiceGlyphKind.micFilled,
                          color: brand.brand,
                          size: 24,
                        )
                      : Icon(
                          Icons.pause_rounded,
                          key: const ValueKey('voice-pause-icon'),
                          color: brand.brand,
                          size: 24,
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
