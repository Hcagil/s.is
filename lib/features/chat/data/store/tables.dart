import 'package:drift/drift.dart';

/// Stored message row.
@DataClassName('StoredMessageRow')
@TableIndex(
  name: 'messages_conversation_created',
  columns: {#conversationId, #createdAt},
)
class Messages extends Table {
  TextColumn get id => text()();

  TextColumn get conversationId => text()();

  TextColumn get senderId => text()();

  IntColumn get createdAt => integer()();

  TextColumn get body => text()();

  TextColumn get bodyFolded => text()();

  IntColumn get editedAt => integer().nullable()();

  TextColumn get deleted => text().nullable()();

  TextColumn get deletedBy => text().nullable()();

  TextColumn get replyTo => text().nullable()();

  BoolColumn get forwarded => boolean().withDefault(const Constant(false))();

  BoolColumn get poll => boolean().withDefault(const Constant(false))();

  BoolColumn get contact => boolean().withDefault(const Constant(false))();

  TextColumn get photoGroup => text().nullable()();

  TextColumn get extra => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'messages';
}

/// Stored conversation row.
@DataClassName('StoredConversationRow')
class Conversations extends Table {
  TextColumn get id => text()();

  TextColumn get json => text()();

  IntColumn get sortAt => integer()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'conversations';
}

/// Stored sync row.
@DataClassName('StoredSyncRow')
class SyncStates extends Table {
  TextColumn get conversationId => text()();

  IntColumn get newestAt => integer().nullable()();

  IntColumn get contiguousFrom => integer().nullable()();

  BoolColumn get complete => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {conversationId};

  @override
  String get tableName => 'sync_state';
}

/// Stored meta row.
@DataClassName('StoredMetaRow')
class Meta extends Table {
  TextColumn get key => text()();

  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};

  @override
  String get tableName => 'meta';
}

/// Stored read/delivery mark of one member of one conversation.
@DataClassName('StoredReadMarkRow')
class ReadMarks extends Table {
  TextColumn get conversationId => text()();

  TextColumn get userId => text()();

  BoolColumn get shares => boolean()();

  IntColumn get readAt => integer().nullable()();

  IntColumn get deliveredAt => integer().nullable()();

  @override
  Set<Column> get primaryKey => {conversationId, userId};

  @override
  String get tableName => 'read_marks';
}

/// Opened locked reaction: the emoji of one member's reaction on one message, keyed by the sha256 of the ciphertext it came from.
@DataClassName('StoredReactionPlainRow')
class ReactionPlains extends Table {
  TextColumn get messageId => text()();

  TextColumn get userId => text()();

  TextColumn get sealed => text()();

  TextColumn get emoji => text()();

  IntColumn get savedAt => integer()();

  @override
  Set<Column> get primaryKey => {messageId, userId};

  @override
  String get tableName => 'reaction_plains';
}

/// Stored Olm session with one contact (pickle encrypted with the pickle key).
@DataClassName('StoredOlmSessionRow')
class OlmSessions extends Table {
  TextColumn get sessionId => text()();

  TextColumn get peerUserId => text()();

  TextColumn get peerIdentityKey => text()();

  TextColumn get pickle => text()();

  /// Microseconds since epoch.
  IntColumn get lastUsedAt => integer()();

  @override
  Set<Column> get primaryKey => {sessionId};

  @override
  String get tableName => 'olm_sessions';
}

/// One queued send of one member (record = encodeQueue of that single record), with its ciphertext once locked.
@DataClassName('StoredSendQueueRow')
class SendQueueRows extends Table {
  TextColumn get userId => text()();

  TextColumn get id => text()();

  IntColumn get position => integer()();

  TextColumn get record => text()();

  TextColumn get ciphertext => text().nullable()();

  IntColumn get olmType => integer().nullable()();

  @override
  Set<Column> get primaryKey => {userId, id};

  @override
  String get tableName => 'send_queue';
}

/// A decrypted message the notification saved while the app was closed: shown only, never a stored message; a trigger deletes it when the real messages row lands.
@DataClassName('StoredPushInboxRow')
class PushInbox extends Table {
  TextColumn get messageId => text()();

  TextColumn get conversationId => text()();

  TextColumn get senderId => text()();

  TextColumn get body => text()();

  /// sha256 hex of the ciphertext the body was opened from.
  TextColumn get sealed => text()();

  /// Local clock, microseconds since epoch.
  IntColumn get receivedAt => integer()();

  @override
  Set<Column> get primaryKey => {messageId};

  @override
  String get tableName => 'push_inbox';
}
