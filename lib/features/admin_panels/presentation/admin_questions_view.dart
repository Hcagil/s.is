import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../l10n/app_localizations.dart';
import '../application/admin_panels_controller.dart';
import '../domain/admin_models.dart';
import 'admin_question_card.dart';

class AdminQuestionsView extends ConsumerStatefulWidget {
  const AdminQuestionsView({super.key});

  @override
  ConsumerState<AdminQuestionsView> createState() => _AdminQuestionsViewState();
}

class _AdminQuestionsViewState extends ConsumerState<AdminQuestionsView> {
  final Map<String, int> _sel = {};
  final Map<String, TextEditingController> _ctl = {};
  bool _sending = false;

  TextEditingController _controller(String id) =>
      _ctl.putIfAbsent(id, TextEditingController.new);

  String? _answerOf(AdminQuestion q) {
    final sel = _sel[q.id] ?? -1;
    final typed = _controller(q.id).text.trim();
    if (q.kind == 'action') {
      return sel == 0
          ? (q.answers.isNotEmpty ? q.answers.first : 'done')
          : null;
    }
    if (q.kind == 'text') {
      return typed.isEmpty ? null : typed;
    }
    if (sel >= 0 && sel < q.answers.length) {
      return q.answers[sel];
    }
    if (sel == q.answers.length) {
      return typed.isEmpty ? null : typed;
    }
    return null;
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(adminPanelsProvider);
    final l = AppLocalizations.of(context);

    if (!s.hasSnapshot) {
      return const Align(
        alignment: Alignment.topCenter,
        child: SisProgressLine(),
      );
    }

    final list = List<AdminQuestion>.from(s.snapshot.questions)
      ..sort((a, b) => a.id.compareTo(b.id));

    if (list.isEmpty) {
      return Center(child: Text(l.adminQuestionsEmpty));
    }

    final ready = list
        .where(
          (q) =>
              !q.waiting &&
              !s.sentQuestions.contains(q.id) &&
              _answerOf(q) != null,
        )
        .toList();

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final q in list)
                AdminQuestionCard(
                  key: ValueKey('admin-question-${q.id}'),
                  question: q,
                  waiting: q.waiting || s.sentQuestions.contains(q.id),
                  selected: _sel[q.id] ?? -1,
                  controller: _controller(q.id),
                  onSelected: (i) => setState(() => _sel[q.id] = i),
                  onTextChanged: () => setState(() {}),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('admin-send'),
              onPressed: ready.isEmpty || _sending ? null : () => _send(ready),
              child: Text(l.adminSend(ready.length)),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _send(List<AdminQuestion> ready) async {
    setState(() => _sending = true);
    for (final q in ready) {
      final a = _answerOf(q);
      if (a == null) continue;
      final f = await ref
          .read(adminPanelsProvider.notifier)
          .answerQuestion(q.id, a);
      if (!mounted) return;
      if (f != null) {
        showSisNotice(
          context,
          AppLocalizations.of(context).adminSendFailed,
          isError: true,
        );
        break;
      } else {
        _sel.remove(q.id);
        _controller(q.id).clear();
      }
    }
    if (mounted) {
      setState(() => _sending = false);
    }
  }
}
