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
