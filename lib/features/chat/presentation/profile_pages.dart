import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../core/failure.dart';
import '../../auth/application/session_controller.dart';
import '../../auth/domain/member.dart';
import '../../auth/domain/session_state.dart';
import '../../notifications/domain/notification_settings.dart';
import '../../notifications/presentation/alert_widgets.dart';
import '../../notifications/presentation/notification_pages.dart';
import '../../presence/application/presence_controllers.dart';
import '../../presence/domain/last_seen.dart';
import '../application/chat_controllers.dart';
import '../application/group_controller.dart';
import '../domain/group_member.dart';
import '../domain/message.dart';
import 'add_members_page.dart';
import 'avatar_card.dart';
import 'message_screen.dart';
import 'person_avatar.dart';
import 'photo_viewer.dart';

part 'person_screen.dart';
part 'group_screen.dart';
part 'members_tab.dart';
part 'media_tab.dart';
part 'links_tab.dart';
part 'system_chat_screen.dart';

/// Loading, failure with its reason, empty, or the list.
class _Async<T> extends StatelessWidget {
  const _Async(this.value, {required this.empty, required this.builder});

  final AsyncValue<List<T>> value;
  final String empty;
  final Widget Function(List<T>) builder;

  @override
  Widget build(BuildContext context) => switch (value) {
    AsyncData(:final value) when value.isEmpty => _Empty(empty),
    AsyncData(:final value) => builder(value),
    AsyncError(:final error) => _Empty(failureReason(error)),
    _ => const Center(child: SisLoadingLogo(size: 40)),
  };
}

class _Empty extends StatelessWidget {
  const _Empty(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ),
  );
}
