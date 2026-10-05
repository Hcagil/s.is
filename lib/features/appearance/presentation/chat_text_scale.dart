import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../application/appearance_controller.dart';

/// SisApp already scales all text by the app text size; this makes the chat's
/// text the chat size instead (relative factor), so a chat bubble shows system
/// scale x chat size.
class ChatTextScale extends ConsumerWidget {
  const ChatTextScale({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = ref.watch(appearanceProvider);
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: sisTextScaler(
          MediaQuery.textScalerOf(context),
          look.chatTextSize.scale / look.appTextSize.scale,
        ),
      ),
      child: child,
    );
  }
}
