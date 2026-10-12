import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/session_controller.dart';

/// Ids of the messages whose video the site refused to play inside the app.
/// Their card shows the plain link card (no play mark) until the app restarts.
final videoRefusedProvider = NotifierProvider<VideoRefused, Set<String>>(
  VideoRefused.new,
);

/// Holds the refused message ids.
class VideoRefused extends Notifier<Set<String>> {
  @override
  Set<String> build() {
    // Another account on this phone starts clean.
    ref.watch(currentUserIdProvider);
    return const {};
  }

  /// Remember that the video of message [id] cannot play here.
  void refuse(String id) {
    if (!state.contains(id)) state = {...state, id};
  }
}
