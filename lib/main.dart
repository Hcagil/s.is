import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'runtime_config.dart';
import 'secure_session_storage.dart';
import 'session_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final config = RuntimeConfig.fromEnvironment();
  if (!config.isComplete) {
    runApp(SisApp(controller: SessionController.unconfigured()));
    return;
  }

  try {
    await Supabase.initialize(
      url: config.supabaseUrl,
      publishableKey: config.supabasePublishableKey,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        localStorage: SecureSessionStorage(),
      ),
    );
    final client = Supabase.instance.client;
    runApp(
      SisApp(
        controller: SessionController.connected(
          initiallySignedIn: client.auth.currentSession != null,
          signedInChanges: client.auth.onAuthStateChange.map(
            (state) => state.session != null,
          ),
          activateSession: () async =>
              await client.rpc('activate_session') == true,
          loadMemberProfiles: () async {
            final currentUserId = client.auth.currentUser!.id;
            final rows = await client
                .from('profiles')
                .select('user_id, display_name')
                .neq('user_id', currentUserId)
                .order('display_name');
            return rows
                .map(
                  (row) => MemberProfile(
                    userId: row['user_id'] as String,
                    displayName: row['display_name'] as String,
                  ),
                )
                .toList(growable: false);
          },
          startGoogleSignIn: () async {
            await client.auth.signInWithOAuth(
              OAuthProvider.google,
              redirectTo: config.authRedirectUri,
              authScreenLaunchMode: LaunchMode.externalApplication,
            );
          },
          performSignOut: client.auth.signOut,
        ),
      ),
    );
  } catch (_) {
    runApp(SisApp(controller: SessionController.failed()));
  }
}

class SisApp extends StatefulWidget {
  const SisApp({super.key, required this.controller});

  final SessionController controller;

  @override
  State<SisApp> createState() => _SisAppState();
}

class _SisAppState extends State<SisApp> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SIS',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) => _SessionGate(controller: widget.controller),
      ),
    );
  }
}

class _SessionGate extends StatelessWidget {
  const _SessionGate({required this.controller});

  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    return switch (controller.status) {
      SessionStatus.setupRequired => const _MessageScreen(
        icon: Icons.settings_outlined,
        title: 'Setup required',
        message:
            'Build with SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, and '
            'AUTH_REDIRECT_URI to connect SIS.',
      ),
      SessionStatus.signedOut => _ActionScreen(
        icon: Icons.forum_outlined,
        title: 'Stay in sync',
        message: 'Sign in with an approved Google account.',
        actionLabel: 'Continue with Google',
        onPressed: controller.signIn,
      ),
      SessionStatus.loading => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      SessionStatus.allowed => _AuthorizedHome(controller: controller),
      SessionStatus.denied => _ActionScreen(
        icon: Icons.lock_outline,
        title: 'Access denied',
        message: 'This Google account is not currently approved for SIS.',
        actionLabel: 'Sign out',
        onPressed: controller.signOut,
      ),
      SessionStatus.error =>
        controller.canRetry
            ? _ActionScreen(
                icon: Icons.cloud_off_outlined,
                title: 'Could not connect',
                message: 'Check your connection and try again.',
                actionLabel: 'Try again',
                onPressed: controller.retry,
              )
            : const _MessageScreen(
                icon: Icons.error_outline,
                title: 'Could not start SIS',
                message: 'Check the runtime configuration and restart the app.',
              ),
    };
  }
}

class _MessageScreen extends StatelessWidget {
  const _MessageScreen({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 48),
                const SizedBox(height: 16),
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ActionScreen extends StatelessWidget {
  const _ActionScreen({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onPressed,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 48),
                const SizedBox(height: 16),
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(onPressed: onPressed, child: Text(actionLabel)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthorizedHome extends StatefulWidget {
  const _AuthorizedHome({required this.controller});

  final SessionController controller;

  @override
  State<_AuthorizedHome> createState() => _AuthorizedHomeState();
}

class _AuthorizedHomeState extends State<_AuthorizedHome> {
  var _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      const _EmptyPage(
        icon: Icons.chat_bubble_outline,
        message: 'No conversations yet',
      ),
      widget.controller.members.isEmpty
          ? const _EmptyPage(
              icon: Icons.people_outline,
              message: 'No other members are available',
            )
          : ListView.builder(
              itemCount: widget.controller.members.length,
              itemBuilder: (context, index) {
                final member = widget.controller.members[index];
                return ListTile(
                  leading: CircleAvatar(
                    child: Text(member.displayName.characters.first),
                  ),
                  title: Text(member.displayName),
                );
              },
            ),
      Center(
        child: OutlinedButton(
          onPressed: widget.controller.signOut,
          child: const Text('Sign out'),
        ),
      ),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('SIS')),
      body: SafeArea(child: pages[_selectedIndex]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (value) =>
            setState(() => _selectedIndex = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            label: 'Conversations',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            label: 'Members',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class _EmptyPage extends StatelessWidget {
  const _EmptyPage({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40),
          const SizedBox(height: 12),
          Text(message),
        ],
      ),
    );
  }
}
