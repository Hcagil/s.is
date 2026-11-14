import 'admin_models.dart';

/// Returns the distinct filter values present among [cards] of [type], sorted.
///
/// For type 'rule': splits each card.applies on ',', trims each part, drops
/// empty strings, and collects the result into a set.
/// For type 'app': collects each non-null, non-empty card.area into a set.
List<String> adminCardValues(List<AdminCard> cards, String type) {
  final Set<String> values = {};
  for (final card in cards) {
    if (card.type != type) continue;
    if (type == 'rule') {
      final applies = card.applies;
      if (applies == null) continue;
      for (final part in applies.split(',')) {
        final trimmed = part.trim();
        if (trimmed.isNotEmpty) {
          values.add(trimmed);
        }
      }
    } else if (type == 'app') {
      final area = card.area;
      if (area != null && area.isNotEmpty) {
        values.add(area);
      }
    }
  }
  return values.toList()..sort();
}

/// Returns the cards that pass ALL of the provided filters.
///
/// Filters:
/// - [state]: if not null, card.state must equal [state].
/// - [type]: if not null, card.type must equal [type].
/// - [value]: if not null, for 'rule' cards the trimmed comma-split parts of
///   card.applies must contain [value]; for 'app' cards card.area must equal
///   [value].
/// - [query]: if not empty (after trimming), it must be contained
///   case-insensitively in card.id, card.oneLiner, any entry of card.words,
///   card.allows or card.forbids.
List<AdminCard> adminFilterCards(
  List<AdminCard> cards, {
  String query = '',
  String? state,
  String? type,
  String? value,
}) {
  final List<AdminCard> result = [];
  final trimmedQuery = query.trim();
  final hasQuery = trimmedQuery.isNotEmpty;

  for (final card in cards) {
    // Check state filter
    if (state != null && card.state != state) continue;

    // Check type filter
    if (type != null && card.type != type) continue;

    // Check value filter
    if (value != null) {
      if (card.type == 'rule') {
        final applies = card.applies;
        if (applies == null) continue;
        bool found = false;
        for (final part in applies.split(',')) {
          if (part.trim() == value) {
            found = true;
            break;
          }
        }
        if (!found) continue;
      } else if (card.type == 'app') {
        if (card.area != value) continue;
      }
    }

    // Check query filter
    if (hasQuery) {
      final lowerQuery = trimmedQuery.toLowerCase();
      bool found = false;

      // Check id
      if (card.id.toLowerCase().contains(lowerQuery)) {
        found = true;
      }
      // Check oneLiner
      else if (card.oneLiner.toLowerCase().contains(lowerQuery)) {
        found = true;
      }
      // Check words
      else if (card.words.any((w) => w.toLowerCase().contains(lowerQuery))) {
        found = true;
      }
      // Check allows
      else if (card.allows != null &&
          card.allows!.toLowerCase().contains(lowerQuery)) {
        found = true;
      }
      // Check forbids
      else if (card.forbids != null &&
          card.forbids!.toLowerCase().contains(lowerQuery)) {
        found = true;
      }

      if (!found) continue;
    }

    result.add(card);
  }

  return result.toList();
}
