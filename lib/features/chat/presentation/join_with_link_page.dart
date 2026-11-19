import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/theme.dart';
import '../../../core/failure.dart';
import '../../../l10n/app_localizations.dart';
import '../application/invite_link_controller.dart';
import '../domain/invite_link.dart';
import 'invite_join_page.dart';
import 'invite_refused_page.dart';

Future<void> showJoinWithLinkPage(BuildContext context) => Navigator.of(context)
    .push<void>(MaterialPageRoute(builder: (_) => const JoinWithLinkPage()));

class JoinWithLinkPage extends ConsumerStatefulWidget {
  const JoinWithLinkPage({super.key});

  @override
  ConsumerState<JoinWithLinkPage> createState() => _JoinWithLinkPageState();
}

class _JoinWithLinkPageState extends ConsumerState<JoinWithLinkPage> {
  final _field = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || !mounted) return;
    setState(() {
      _field.text = text;
      _error = null;
    });
  }

  Future<void> _continue() async {
    final text = _field.text;
    final l = AppLocalizations.of(context);
    if (inviteCodeFrom(text) == null) {
      setState(() => _error = l.joinLinkNotInvite);
      return;
    }
    setState(() => _busy = true);
    final navigator = Navigator.of(context);
    final r = await ref.read(inviteLinkControllerProvider).preview(text);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (r) {
      case Ok(:final value):
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) =>
                InviteJoinPage(code: inviteCodeFrom(text)!, preview: value),
          ),
        );
      case Err(failure: final InviteLinkFailure f):
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => InviteRefusedPage(problem: f.problem),
          ),
        );
      case Err(failure: final SearchLimitFailure _):
        setState(() => _error = l.joinLinkTooManyTries);
      case Err(failure: final NetworkFailure n) when n.retryable:
        setState(() => _error = l.joinLinkOffline);
      case Err(:final failure):
        setState(() => _error = failure.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final muted = SisBrand.of(context).muted;
    final canContinue = !_busy && _field.text.trim().isNotEmpty;
    return Scaffold(
      key: const ValueKey('join-link-page'),
      appBar: AppBar(title: Text(l.joinLinkTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            key: const ValueKey('join-link-field'),
            controller: _field,
            decoration: InputDecoration(
              hintText: l.joinLinkHint,
              errorText: _error,
              suffixIcon: TextButton(
                key: const ValueKey('join-link-paste'),
                onPressed: _paste,
                child: Text(l.commonPaste),
              ),
            ),
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 8),
          Text(l.joinLinkHelp, style: TextStyle(color: muted)),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('join-link-continue'),
              onPressed: canContinue ? _continue : null,
              child: Text(l.commonContinue),
            ),
          ),
        ],
      ),
    );
  }
}
