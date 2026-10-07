// Fakes for Send a contact, derived from the PhoneBook and
// ContactShareRepository interfaces (not from any implementation). Both can
// be held mid-call with a gate, like the real platform prompt and network.
import 'dart:async';

import 'package:sis/core/failure.dart';
import 'package:sis/features/chat/domain/contact_share_repository.dart';
import 'package:sis/features/chat/domain/phone_book.dart';
import 'package:sis/features/chat/domain/shared_contact.dart';

/// The phone's contacts. [access] is what the (first) system prompt answers;
/// later asks answer without prompting, as the interface says. [entries]
/// returns an empty list without access, like the real one.
class FakePhoneBook implements PhoneBook {
  FakePhoneBook({
    this.access = PhoneBookAccess.granted,
    List<PhoneBookEntry>? contacts,
  }) : contacts = contacts ?? [];

  PhoneBookAccess access;
  List<PhoneBookEntry> contacts;

  int accessCalls = 0;
  int entriesCalls = 0;
  int settingsCalls = 0;
  final added = <SharedContact>[];

  /// When set, requestAccess waits for it (the system prompt is on screen).
  Completer<void>? prompt;

  @override
  Future<PhoneBookAccess> requestAccess() async {
    accessCalls++;
    final p = prompt;
    if (p != null) await p.future;
    return access;
  }

  @override
  Future<List<PhoneBookEntry>> entries() async {
    entriesCalls++;
    if (access != PhoneBookAccess.granted) return const [];
    return List.of(contacts);
  }

  @override
  Future<void> openSettings() async => settingsCalls++;

  @override
  Future<void> addToPhone(SharedContact contact) async => added.add(contact);
}

/// The server side of send_contact. [answer] decides the result; a [gate]
/// holds the call in flight.
class FakeContactShare implements ContactShareRepository {
  final calls = <(String, String, SharedContact)>[];
  Result<void> answer = const Ok(null);
  Completer<void>? gate;

  @override
  Future<Result<void>> send(
    String conversationId,
    String messageId,
    SharedContact contact,
  ) async {
    calls.add((conversationId, messageId, contact));
    final g = gate;
    if (g != null) await g.future;
    return answer;
  }
}
