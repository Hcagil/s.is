import 'message.dart';

/// What the phone knows about how much of one chat's history it holds.
final class StoredSync {
  const StoredSync({this.newestAt, this.contiguousFrom, this.complete = false});

  /// Time of the newest stored message of the last server page.
  final DateTime? newestAt;

  /// Oldest message time such that every message from there up to [newestAt]
  /// is stored (no gap).
  final DateTime? contiguousFrom;

  /// True once the first message of the chat is stored (nothing older exists).
  final bool complete;
}

/// Where the account-wide change feed was read up to: the server row time and
/// id of the last change applied.
final class ChangeCursor {
  const ChangeCursor(this.updatedAt, this.id);
  final DateTime updatedAt;
  final String id;
}

/// The messages kept on the phone (encrypted at rest), so a chat can show at
/// once, before the server answers, and be searched on the phone.
///
/// Every method is best-effort and must never throw: the store is a
/// convenience for the first frame and for search, never the source of truth.
/// A failed read returns an empty/null value, a failed write is skipped.
abstract interface class MessageStore {
  /// Newest [limit] stored messages of [conversationId], oldest first.
  Future<List<Message>> newest(String conversationId, {int limit = 50});

  /// Up to [limit] stored messages strictly older than [before], oldest first.
  Future<List<Message>> older(
    String conversationId,
    DateTime before, {
    int limit = 50,
  });

  /// Up to [each] stored messages on each side of [messageId] plus that
  /// message, oldest first; empty when [messageId] is not stored.
  Future<List<Message>> around(
    String conversationId,
    String messageId, {
    int each = 50,
  });

  /// Inserts or replaces [messages] by id, in one transaction. A pending
  /// message is never stored.
  Future<void> upsertAll(List<Message> messages);

  /// Applies a page the server just returned for [conversationId] (oldest
  /// first) in one transaction: upserts it, deletes stored rows of the same
  /// time range that the server no longer returns (everything, when
  /// [reachedStart]), and moves the chat's [StoredSync]. [reachedStart] is
  /// true when the page is shorter than the page size, i.e. it holds the
  /// first message.
  Future<void> reconcilePage(
    String conversationId,
    List<Message> page, {
    required bool reachedStart,
  });

  /// Stores an OLDER page of [conversationId] (oldest first), fetched by the
  /// background fill: upserts it in one transaction and lowers the chat's
  /// contiguousFrom to the page's oldest row. Unlike [reconcilePage] it never
  /// moves newestAt and deletes nothing. [reachedStart] marks the chat complete
  /// (the page was short, so it holds the first message). Does nothing when the
  /// chat has no sync state yet (no newest page was reconciled first).
  Future<void> extendOlder(
    String conversationId,
    List<Message> page, {
    required bool reachedStart,
  });

  /// Removes one stored message (hidden for me, vanished).
  Future<void> remove(String messageId);

  /// Removes every stored message and the sync state of [conversationId].
  Future<void> deleteConversation(String conversationId);

  /// Stored, not deleted messages containing [query], newest first, at most
  /// [limit]. [query] is folded (see foldSearch) here; one that is not
  /// isSearchable returns an empty list. Restricted to [conversationId] when
  /// given.
  Future<List<Message>> search(
    String query, {
    String? conversationId,
    int limit = 100,
  });

  /// The sync state of [conversationId], or null when nothing was stored yet.
  Future<StoredSync?> syncState(String conversationId);

  /// The account-wide change cursor, or null on a fresh store.
  Future<ChangeCursor?> cursor();

  /// Saves the change cursor.
  Future<void> saveCursor(ChangeCursor cursor);

  /// Ids of every chat that has stored messages, a sync state or a list row.
  Future<Set<String>> conversationIds();

  /// Closes the store and deletes the database file; used at sign-out.
  Future<void> clear();
}
