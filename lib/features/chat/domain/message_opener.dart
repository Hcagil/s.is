import 'message.dart';

/// Opens locked (Olm-encrypted) text messages that came from the server, once, on this phone. Every path that reads message rows from the server runs them through [open] before anything shows or stores them.
abstract interface class MessageOpener {
  /// Returns [rows] in the same order. A row without ciphertext, a deleted row and a row of a non-text kind pass unchanged. A locked row from another member comes back with its plaintext as body and link card (ciphertext cleared, `sealed` set) after it was opened exactly once and stored; one that cannot be opened (no session yet, or unreadable) comes back with the locked placeholder body, never with ciphertext. A locked row sent by this member comes back with the plaintext this phone stored for it (never decrypted); without a stored copy it keeps the placeholder. Never throws.
  ///
  /// [fresh] is true only for rows that just arrived (a live insert or the forward change feed), never for a first page or for older history pages; a plain text from another member that is not yet stored, in a chat that already held an opened locked text, then comes back locked whatever its date says.
  Future<List<Message>> open(List<Message> rows, {bool fresh = false});

  /// Rows that could not be opened for lack of a session and were opened later, when the session appeared; each is the same message as before with its plaintext.
  Stream<Message> get reopened;

  /// Stops waiting for the row [id]: it was hidden or vanished on this phone, so it must never be opened and shown later.
  void forget(String id);
}
