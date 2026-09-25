import 'package:flutter/material.dart';

import 'brand.dart';
import 'theme.dart';

/// The Sync S, gently pulsing: every full-screen and inline wait (replaces
/// CircularProgressIndicator). Static when the platform asks for reduced
/// motion.
class SisLoadingLogo extends StatefulWidget {
  const SisLoadingLogo({super.key, this.size = 72});

  final double size;

  @override
  State<SisLoadingLogo> createState() => _SisLoadingLogoState();
}

class _SisLoadingLogoState extends State<SisLoadingLogo>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logo = SisLogo(size: widget.size);
    if (MediaQuery.disableAnimationsOf(context)) return logo;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Opacity(
        opacity: .55 + .45 * _controller.value,
        child: Transform.scale(
          scale: .92 + .08 * _controller.value,
          child: child,
        ),
      ),
      child: logo,
    );
  }
}

/// A full-screen wait: the pulsing logo, centred.
class SisFullScreenLoader extends StatelessWidget {
  const SisFullScreenLoader({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: SisLoadingLogo()));
}

/// A thin brand-gradient line: every small/inline wait (replaces
/// LinearProgressIndicator).
class SisProgressLine extends StatelessWidget {
  const SisProgressLine({super.key});

  @override
  Widget build(BuildContext context) {
    final t = SisBrand.of(context);
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => t.gradient.createShader(bounds),
      child: const LinearProgressIndicator(
        minHeight: 3,
        backgroundColor: Colors.transparent,
        valueColor: AlwaysStoppedAnimation(Colors.white),
      ),
    );
  }
}
