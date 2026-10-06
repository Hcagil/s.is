import '../../../l10n/app_localizations.dart';
import '../domain/conversation.dart';

/// A member's name for display. The data layer returns an empty name when a
/// profile is unknown; this is where it becomes the localised "Member".
String nameOrMember(AppLocalizations l, String name) =>
    name.isEmpty ? l.commonMember : name;

/// A conversation's name for display; an unknown 1:1 partner shows "Member".
String conversationLabel(AppLocalizations l, Conversation c) =>
    nameOrMember(l, c.label);
