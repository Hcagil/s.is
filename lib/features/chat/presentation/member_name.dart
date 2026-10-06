import '../../../l10n/app_localizations.dart';

/// A member's name for display. The data layer returns an empty name when a
/// profile is unknown; this is where it becomes the localised "Member".
String nameOrMember(AppLocalizations l, String name) =>
    name.isEmpty ? l.commonMember : name;
