part of 'profile_pages.dart';

/// The SIS chat's profile page: only mute, since it cannot be left or
/// written into.
class SystemChatScreen extends StatelessWidget {
  const SystemChatScreen({super.key, required this.conversationId});

  final String conversationId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Column(
        children: [
          PersonAvatar(label: 'SIS', seed: conversationId, radius: 48),
          const SizedBox(height: 12),
          Text(
            'SIS',
            key: const ValueKey('system-name'),
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
          Text(
            AppLocalizations.of(context).systemChatSubtitle,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          MuteTile(kind: MuteKind.conversation, target: conversationId),
        ],
      ),
    );
  }
}
