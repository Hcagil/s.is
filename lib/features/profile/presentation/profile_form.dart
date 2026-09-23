import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/failure.dart';
import '../application/profile_controller.dart';
import '../domain/own_profile.dart';

/// Name and tag, with a live availability check on the tag.
///
/// Shared by the first-run screen and settings so the two cannot disagree
/// about what a valid name or tag is.
class ProfileForm extends ConsumerStatefulWidget {
  const ProfileForm({
    super.key,
    required this.profile,
    required this.submitLabel,
    required this.onSubmit,
  });

  final OwnProfile profile;
  final String submitLabel;

  /// Receives the trimmed name and normalised tag; returns the outcome so the
  /// form can show a refusal's reason under the field it concerns.
  final Future<Result<OwnProfile>> Function(String displayName, String tag)
  onSubmit;

  @override
  ConsumerState<ProfileForm> createState() => _ProfileFormState();
}

enum _TagState { unchanged, checking, free, taken, invalid, unknown }

class _ProfileFormState extends ConsumerState<ProfileForm> {
  late final _name = TextEditingController(text: widget.profile.displayName);
  late final _tag = TextEditingController(text: widget.profile.tag);
  Timer? _debounce;
  _TagState _tagState = _TagState.unchanged;
  String? _tagMessage;
  String? _error;
  bool _saving = false;
  int _check = 0; // discards answers to superseded checks

  @override
  void dispose() {
    _debounce?.cancel();
    _name.dispose();
    _tag.dispose();
    super.dispose();
  }

  void _setTag(_TagState state, String? message) => setState(() {
    _tagState = state;
    _tagMessage = message;
  });

  void _onTagChanged(String input) {
    _debounce?.cancel();
    // Every edit supersedes any check still in flight -- including edits that
    // never start a new check (a malformed tag, or back to the current one),
    // whose late answer would otherwise overwrite what the form now shows.
    ++_check;
    final tag = normaliseTag(input);
    if (tag == widget.profile.tag) {
      _setTag(_TagState.unchanged, null);
      return;
    }
    final problem = tagProblem(tag);
    if (problem != null) {
      _setTag(_TagState.invalid, problem);
      return;
    }
    _setTag(_TagState.checking, 'Checking…');
    final ticket = _check;
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final result = await ref.read(ownProfileProvider.notifier).checkTag(tag);
      if (!mounted || ticket != _check) return;
      switch (result) {
        case Ok(value: true):
          _setTag(_TagState.free, '@$tag is available');
        case Ok(value: false):
          _setTag(_TagState.taken, '@$tag is taken');
        case Err():
          // Could not check: let the save decide rather than block the form.
          _setTag(_TagState.unknown, 'Could not check availability');
      }
    });
  }

  bool get _canSubmit =>
      !_saving &&
      displayNameProblem(_name.text) == null &&
      switch (_tagState) {
        _TagState.unchanged || _TagState.free || _TagState.unknown => true,
        _ => false,
      };

  Future<void> _submit() async {
    if (!_canSubmit) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final result = await widget.onSubmit(
      _name.text.trim(),
      normaliseTag(_tag.text),
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (result case Err(:final failure)) _error = failure.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final nameProblem = _name.text.isEmpty
        ? null
        : displayNameProblem(_name.text);
    final tagIsBad =
        _tagState == _TagState.invalid || _tagState == _TagState.taken;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('profile-name'),
          controller: _name,
          maxLength: maxDisplayNameLength,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: 'Display name',
            helperText: 'Shown to other members. Need not be unique.',
            errorText: nameProblem,
            counterText: '',
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('profile-tag'),
          controller: _tag,
          maxLength: 21,
          autocorrect: false,
          onChanged: _onTagChanged,
          decoration: InputDecoration(
            labelText: 'Tag',
            prefixText: '@',
            helperText:
                _tagMessage ?? 'Unique. Letters, digits and _; 3 to 20.',
            errorText: tagIsBad ? _tagMessage : null,
            counterText: '',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            key: const ValueKey('profile-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        const SizedBox(height: 16),
        FilledButton(
          key: const ValueKey('profile-submit'),
          onPressed: _canSubmit ? _submit : null,
          child: Text(widget.submitLabel),
        ),
      ],
    );
  }
}
