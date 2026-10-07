/// A phone contact travelling in a message; the message body is `name`, a
/// line break, `phone`, so an older build shows it as plain text.
final class SharedContact {
  /// Creates a contact with the given name and phone.
  const SharedContact({required this.name, required this.phone});

  /// Returns a contact with cleaned name and phone.
  factory SharedContact.clean(String name, String phone) {
    final cleanName = String.fromCharCodes(
      cleanContactText(name).runes.take(contactMaxNameLength),
    );
    return SharedContact(name: cleanName, phone: cleanContactText(phone));
  }

  /// The contact's name.
  final String name;

  /// The contact's phone number.
  final String phone;

  /// The message body of this contact.
  String get body => '$name\n$phone';

  /// Whether this contact can be sent.
  bool get isSendable =>
      name.isNotEmpty &&
      name.runes.length <= contactMaxNameLength &&
      phone.length >= contactMinPhoneLength &&
      phone.length <= contactMaxPhoneLength &&
      name == cleanContactText(name) &&
      phone == cleanContactText(phone);

  /// Tries to parse a contact from the given body.
  static SharedContact? tryParse(String body) {
    final i = body.lastIndexOf('\n');
    if (i <= 0 || i == body.length - 1) return null;
    return SharedContact(
      name: body.substring(0, i),
      phone: body.substring(i + 1),
    );
  }
}

/// Collapses every run of whitespace/control chars to one space and trims.
String cleanContactText(String text) {
  return text.replaceAll(RegExp(r'[\s\p{Cc}]+', unicode: true), ' ').trim();
}

/// The maximum length of a contact's name.
const int contactMaxNameLength = 80;

/// The minimum length of a contact's phone number.
const int contactMinPhoneLength = 3;

/// The maximum length of a contact's phone number.
const int contactMaxPhoneLength = 32;

/// The prefix used to mark a contact preview in the chat list.
const String contactPreviewPrefix = '\u{1F464} Contact: ';

/// Returns the chat-list line of a contact message.
String contactPreview(String body) {
  final c = SharedContact.tryParse(body);
  return '$contactPreviewPrefix${c?.name ?? cleanContactText(body)}';
}
