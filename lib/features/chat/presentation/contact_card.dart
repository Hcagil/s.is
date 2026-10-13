import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/app_localizations.dart';
import '../application/chat_controllers.dart';
import '../domain/message.dart';
import '../domain/shared_contact.dart';
import 'person_avatar.dart';

class ContactCard extends ConsumerWidget {
  const ContactCard({
    super.key,
    required this.message,
    required this.ink,
    required this.accent,
    required this.time,
  });

  final Message message;
  final Color ink;
  final Color accent;
  final Widget time;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final contact = SharedContact.tryParse(message.body);
    if (contact == null) {
      return Column(
        key: ValueKey('contact-${message.id}'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message.body, style: TextStyle(fontSize: 15, color: ink)),
          Align(alignment: Alignment.centerRight, child: time),
        ],
      );
    }

    return SizedBox(
      key: ValueKey('contact-${message.id}'),
      width: 240,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              PersonAvatar(
                label: contact.name,
                seed: contact.phone,
                radius: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      contact.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: ink,
                      ),
                    ),
                    Text(
                      contact.phone,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: ink.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: ink.withValues(alpha: 0.18)),
              ),
            ),
            child: Row(
              children: [
                InkWell(
                  key: ValueKey('contact-save-${message.id}'),
                  onTap: message.sending
                      ? null
                      : () => ref.read(phoneBookProvider).addToPhone(contact),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 4,
                    ),
                    child: Text(
                      AppLocalizations.of(context).commonSave,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: message.sending
                            ? ink.withValues(alpha: 0.5)
                            : accent,
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                time,
              ],
            ),
          ),
        ],
      ),
    );
  }
}
