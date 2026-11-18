import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/notice.dart';
import '../../../l10n/app_localizations.dart';
import '../application/admin_drafts.dart';
import '../application/admin_panels_controller.dart';
import '../application/admin_panels_state.dart';
import '../domain/admin_answer.dart';
import '../domain/admin_models.dart';
import '../domain/admin_question_groups.dart';
import 'admin_question_card.dart';
import 'admin_question_group_header.dart';
import 'admin_answer_status.dart';

class AdminQuestionsView extends ConsumerStatefulWidget {
  const AdminQuestionsView({super.key});

  @override
  ConsumerState<AdminQuestionsView> createState() => _AdminQuestionsViewState();
}

class _AdminQuestionsViewState extends ConsumerState<AdminQuestionsView> {
  late final _drafts = ref.read(adminDraftsProvider);
  final Set<String> _restored = {};
  final Map<String, int> _sel = {};
  final Map<String, TextEditingController> _ctl = {};
  bool _sending = false;
  final Set<String> _open = {};
  final Set<String> _closed = {};
  final Set<String> _gOpen = {};
  final Set<String> _gClosed = {};

  TextEditingController _controller(String id) =>
      _ctl.putIfAbsent(id, TextEditingController.new);

  void _restore(AdminQuestion q) {
    if (!_restored.add(q.id)) return;
    unawaited(
      _drafts.read(adminQuestionDraftKey(q.id)).then((t) {
        final c = _controller(q.id);
        if (!mounted || t.isEmpty || c.text.isNotEmpty) return;
        c.text = t;
        if (q.kind != 'action' && q.kind != 'text' && !_sel.containsKey(q.id)) {
          _sel[q.id] = q.answers.length;
        }
        setState(() {});
      }),
    );
  }

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
    unawaited(_drafts.flush());
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

    for (final q in list) {
      _restore(q);
    }

    final ready = list
        .where(
          (q) =>
              !q.waiting &&
              !s.sentQuestions.contains(q.id) &&
              _answerOf(q) != null,
        )
        .toList();
    final topId = list
        .where((q) => !q.waiting && !s.sentQuestions.contains(q.id))
        .firstOrNull
        ?.id;

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: _groups(list, s, topId),
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

  List<Widget> _groups(
    List<AdminQuestion> list,
    AdminPanelsState s,
    String? topId,
  ) {
    final top = list.where((q) => q.id == topId).firstOrNull;
    bool open(String key, bool isTop) =>
        _gOpen.contains(key) || (isTop && !_gClosed.contains(key));
    void toggle(String key, bool on) => setState(() {
      if (on) {
        _gOpen.remove(key);
        _gClosed.add(key);
      } else {
        _gClosed.remove(key);
        _gOpen.add(key);
      }
    });
    int waitingCount(Iterable<AdminQuestion> qs) =>
        qs.where((q) => !q.waiting && !s.sentQuestions.contains(q.id)).length;

    final out = <Widget>[];
    for (final t in groupAdminQuestions(list)) {
      final tKey = adminTopicKey(t.name);
      final tOn = open(tKey, top?.topic == t.name);
      out.add(
        AdminQuestionGroupHeader(
          key: ValueKey('admin-question-topic-${t.name}'),
          title: t.name,
          count: waitingCount(t.questions),
          expanded: tOn,
          onToggle: () => toggle(tKey, tOn),
        ),
      );
      if (!tOn) continue;
      for (final sub in t.subs) {
        if (sub.name.isEmpty) {
          out.addAll([for (final q in sub.questions) ..._rows(q, s, topId)]);
          continue;
        }
        final sKey = adminSubKey(t.name, sub.name);
        final sOn = open(sKey, top?.topic == t.name && top?.sub == sub.name);
        out.add(
          AdminQuestionGroupHeader(
            key: ValueKey('admin-question-sub-$sKey'),
            title: sub.name,
            count: waitingCount(sub.questions),
            expanded: sOn,
            onToggle: () => toggle(sKey, sOn),
            indent: 16,
          ),
        );
        if (sOn) {
          out.addAll([for (final q in sub.questions) ..._rows(q, s, topId)]);
        }
      }
    }
    return out;
  }

  // One status per question: 'sending' wins until the computer marks it waiting.
  List<Widget> _rows(AdminQuestion q, AdminPanelsState s, String? topId) {
    _restore(q);
    final on =
        _open.contains(q.id) || (q.id == topId && !_closed.contains(q.id));
    final a = s.latestAnswer('question', id: q.id);
    final sending =
        a != null && a.status == AdminAnswerStatus.sending && !q.waiting;
    return [
      AdminQuestionCard(
        key: ValueKey('admin-question-${q.id}'),
        question: q,
        waiting: !sending && (q.waiting || s.sentQuestions.contains(q.id)),
        selected: _sel[q.id] ?? -1,
        expanded: on,
        onToggle: () => setState(() {
          if (on) {
            _open.remove(q.id);
            _closed.add(q.id);
          } else {
            _closed.remove(q.id);
            _open.add(q.id);
          }
        }),
        controller: _controller(q.id),
        onSelected: (i) => setState(() => _sel[q.id] = i),
        onTextChanged: () {
          unawaited(
            _drafts.write(adminQuestionDraftKey(q.id), _controller(q.id).text),
          );
          setState(() {});
        },
      ),
      if (a != null && (a.status != AdminAnswerStatus.sending || !q.waiting))
        AdminAnswerStatusLine(key: ValueKey('admin-answer-${q.id}'), answer: a),
    ];
  }

  Future<void> _send(List<AdminQuestion> ready) async {
    setState(() => _sending = true);
    for (final q in ready) {
      final a = _answerOf(q);
      if (a == null) continue;
      for (final k in [adminTopicKey(q.topic), adminSubKey(q.topic, q.sub)]) {
        _gClosed.remove(k);
        _gOpen.add(k);
      }
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
        _open.remove(q.id);
        _closed.remove(q.id);
        _controller(q.id).clear();
        unawaited(_drafts.remove(adminQuestionDraftKey(q.id)));
      }
    }
    if (mounted) {
      setState(() => _sending = false);
    }
  }
}
