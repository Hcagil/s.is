import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/loading.dart';
import '../../../app/theme.dart';
import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/phone_book.dart';
import '../domain/shared_contact.dart';
import 'person_avatar.dart';
import 'picker_widgets.dart';

Future<SharedContact?> showContactPicker(BuildContext context) =>
    Navigator.of(context).push<SharedContact>(
      MaterialPageRoute(builder: (_) => const ContactPickerPage()),
    );

class ContactPickerPage extends ConsumerStatefulWidget {
  const ContactPickerPage({super.key});

  @override
  ConsumerState<ContactPickerPage> createState() => _ContactPickerPageState();
}

class _ContactPickerPageState extends ConsumerState<ContactPickerPage> {
  final _search = TextEditingController();
  String _query = '';
  String? _pickedId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final state = ref.watch(phoneBookControllerProvider);
    return Scaffold(
      key: const ValueKey('contact-picker-page'),
      appBar: AppBar(title: Text(l.contactPickerTitle)),
      body: switch (state) {
        AsyncData(value: PhoneBookReady(:final entries)) => _ready(
          context,
          entries,
        ),
        AsyncData(value: PhoneBookDenied(:final permanent)) => _access(
          context,
          permanent,
        ),
        AsyncError() => _access(context, false),
        _ => const Center(child: SisLoadingLogo(size: 48)),
      },
    );
  }

  Widget _ready(BuildContext context, List<PhoneBookEntry> entries) {
    final t = SisBrand.of(context);
    final l = AppLocalizations.of(context);
    final shown = filterPhoneBook(entries, _query);
    PhoneBookEntry? picked;
    for (final e in entries) {
      if (e.id == _pickedId) picked = e;
    }

    return Column(
      children: [
        PickerSearchField(
          fieldKey: const ValueKey('contact-search'),
          controller: _search,
          hint: l.contactSearchHint,
          onChanged: (v) => setState(() => _query = v),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: Text(
                    entries.isEmpty ? l.contactEmpty : l.contactNoMatch,
                    style: TextStyle(color: t.muted),
                  ),
                )
              : ListView.builder(
                  itemCount: shown.length,
                  itemBuilder: (context, i) {
                    final e = shown[i];
                    final on = e.id == _pickedId;
                    return ListTile(
                      key: ValueKey('contact-${e.id}'),
                      leading: PersonAvatar(
                        label: e.name,
                        seed: e.id,
                        radius: 19,
                      ),
                      title: Text(
                        e.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(e.phone),
                      trailing: Icon(
                        on
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: on ? t.brand : t.muted,
                      ),
                      selected: on,
                      onTap: () => setState(() => _pickedId = e.id),
                    );
                  },
                ),
        ),
        PickerBottomBar(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l.contactPermNote,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: t.muted),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  key: const ValueKey('contact-send'),
                  onPressed: picked == null
                      ? null
                      : () => Navigator.of(
                          context,
                        ).pop(SharedContact.clean(picked!.name, picked.phone)),
                  child: Text(l.contactSend),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _access(BuildContext context, bool permanent) {
    final l = AppLocalizations.of(context);
    final t = SisBrand.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: t.surfaceHigh,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Icon(
                      Icons.contacts_outlined,
                      size: 44,
                      color: t.brand,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    l.contactAccessTitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l.contactAccessBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: t.muted),
                  ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: const ValueKey('contact-allow'),
                      onPressed: () => ref
                          .read(phoneBookControllerProvider.notifier)
                          .retryAccess(),
                      child: Text(
                        permanent ? l.attachOpenSettings : l.contactAllowAccess,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
