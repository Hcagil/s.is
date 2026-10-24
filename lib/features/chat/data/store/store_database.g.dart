// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'store_database.dart';

// ignore_for_file: type=lint
class $MessagesTable extends Messages
    with TableInfo<$MessagesTable, StoredMessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _senderIdMeta = const VerificationMeta(
    'senderId',
  );
  @override
  late final GeneratedColumn<String> senderId = GeneratedColumn<String>(
    'sender_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyFoldedMeta = const VerificationMeta(
    'bodyFolded',
  );
  @override
  late final GeneratedColumn<String> bodyFolded = GeneratedColumn<String>(
    'body_folded',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _editedAtMeta = const VerificationMeta(
    'editedAt',
  );
  @override
  late final GeneratedColumn<int> editedAt = GeneratedColumn<int>(
    'edited_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deletedMeta = const VerificationMeta(
    'deleted',
  );
  @override
  late final GeneratedColumn<String> deleted = GeneratedColumn<String>(
    'deleted',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deletedByMeta = const VerificationMeta(
    'deletedBy',
  );
  @override
  late final GeneratedColumn<String> deletedBy = GeneratedColumn<String>(
    'deleted_by',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _replyToMeta = const VerificationMeta(
    'replyTo',
  );
  @override
  late final GeneratedColumn<String> replyTo = GeneratedColumn<String>(
    'reply_to',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _forwardedMeta = const VerificationMeta(
    'forwarded',
  );
  @override
  late final GeneratedColumn<bool> forwarded = GeneratedColumn<bool>(
    'forwarded',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("forwarded" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _pollMeta = const VerificationMeta('poll');
  @override
  late final GeneratedColumn<bool> poll = GeneratedColumn<bool>(
    'poll',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("poll" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _contactMeta = const VerificationMeta(
    'contact',
  );
  @override
  late final GeneratedColumn<bool> contact = GeneratedColumn<bool>(
    'contact',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("contact" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _photoGroupMeta = const VerificationMeta(
    'photoGroup',
  );
  @override
  late final GeneratedColumn<String> photoGroup = GeneratedColumn<String>(
    'photo_group',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _extraMeta = const VerificationMeta('extra');
  @override
  late final GeneratedColumn<String> extra = GeneratedColumn<String>(
    'extra',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    conversationId,
    senderId,
    createdAt,
    body,
    bodyFolded,
    editedAt,
    deleted,
    deletedBy,
    replyTo,
    forwarded,
    poll,
    contact,
    photoGroup,
    extra,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredMessageRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('sender_id')) {
      context.handle(
        _senderIdMeta,
        senderId.isAcceptableOrUnknown(data['sender_id']!, _senderIdMeta),
      );
    } else if (isInserting) {
      context.missing(_senderIdMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('body')) {
      context.handle(
        _bodyMeta,
        body.isAcceptableOrUnknown(data['body']!, _bodyMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyMeta);
    }
    if (data.containsKey('body_folded')) {
      context.handle(
        _bodyFoldedMeta,
        bodyFolded.isAcceptableOrUnknown(data['body_folded']!, _bodyFoldedMeta),
      );
    } else if (isInserting) {
      context.missing(_bodyFoldedMeta);
    }
    if (data.containsKey('edited_at')) {
      context.handle(
        _editedAtMeta,
        editedAt.isAcceptableOrUnknown(data['edited_at']!, _editedAtMeta),
      );
    }
    if (data.containsKey('deleted')) {
      context.handle(
        _deletedMeta,
        deleted.isAcceptableOrUnknown(data['deleted']!, _deletedMeta),
      );
    }
    if (data.containsKey('deleted_by')) {
      context.handle(
        _deletedByMeta,
        deletedBy.isAcceptableOrUnknown(data['deleted_by']!, _deletedByMeta),
      );
    }
    if (data.containsKey('reply_to')) {
      context.handle(
        _replyToMeta,
        replyTo.isAcceptableOrUnknown(data['reply_to']!, _replyToMeta),
      );
    }
    if (data.containsKey('forwarded')) {
      context.handle(
        _forwardedMeta,
        forwarded.isAcceptableOrUnknown(data['forwarded']!, _forwardedMeta),
      );
    }
    if (data.containsKey('poll')) {
      context.handle(
        _pollMeta,
        poll.isAcceptableOrUnknown(data['poll']!, _pollMeta),
      );
    }
    if (data.containsKey('contact')) {
      context.handle(
        _contactMeta,
        contact.isAcceptableOrUnknown(data['contact']!, _contactMeta),
      );
    }
    if (data.containsKey('photo_group')) {
      context.handle(
        _photoGroupMeta,
        photoGroup.isAcceptableOrUnknown(data['photo_group']!, _photoGroupMeta),
      );
    }
    if (data.containsKey('extra')) {
      context.handle(
        _extraMeta,
        extra.isAcceptableOrUnknown(data['extra']!, _extraMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  StoredMessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredMessageRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      senderId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sender_id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      body: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body'],
      )!,
      bodyFolded: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}body_folded'],
      )!,
      editedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}edited_at'],
      ),
      deleted: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}deleted'],
      ),
      deletedBy: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}deleted_by'],
      ),
      replyTo: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}reply_to'],
      ),
      forwarded: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}forwarded'],
      )!,
      poll: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}poll'],
      )!,
      contact: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}contact'],
      )!,
      photoGroup: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}photo_group'],
      ),
      extra: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}extra'],
      ),
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }
}

class StoredMessageRow extends DataClass
    implements Insertable<StoredMessageRow> {
  final String id;
  final String conversationId;
  final String senderId;
  final int createdAt;
  final String body;
  final String bodyFolded;
  final int? editedAt;
  final String? deleted;
  final String? deletedBy;
  final String? replyTo;
  final bool forwarded;
  final bool poll;
  final bool contact;
  final String? photoGroup;
  final String? extra;
  const StoredMessageRow({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.createdAt,
    required this.body,
    required this.bodyFolded,
    this.editedAt,
    this.deleted,
    this.deletedBy,
    this.replyTo,
    required this.forwarded,
    required this.poll,
    required this.contact,
    this.photoGroup,
    this.extra,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['conversation_id'] = Variable<String>(conversationId);
    map['sender_id'] = Variable<String>(senderId);
    map['created_at'] = Variable<int>(createdAt);
    map['body'] = Variable<String>(body);
    map['body_folded'] = Variable<String>(bodyFolded);
    if (!nullToAbsent || editedAt != null) {
      map['edited_at'] = Variable<int>(editedAt);
    }
    if (!nullToAbsent || deleted != null) {
      map['deleted'] = Variable<String>(deleted);
    }
    if (!nullToAbsent || deletedBy != null) {
      map['deleted_by'] = Variable<String>(deletedBy);
    }
    if (!nullToAbsent || replyTo != null) {
      map['reply_to'] = Variable<String>(replyTo);
    }
    map['forwarded'] = Variable<bool>(forwarded);
    map['poll'] = Variable<bool>(poll);
    map['contact'] = Variable<bool>(contact);
    if (!nullToAbsent || photoGroup != null) {
      map['photo_group'] = Variable<String>(photoGroup);
    }
    if (!nullToAbsent || extra != null) {
      map['extra'] = Variable<String>(extra);
    }
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      senderId: Value(senderId),
      createdAt: Value(createdAt),
      body: Value(body),
      bodyFolded: Value(bodyFolded),
      editedAt: editedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(editedAt),
      deleted: deleted == null && nullToAbsent
          ? const Value.absent()
          : Value(deleted),
      deletedBy: deletedBy == null && nullToAbsent
          ? const Value.absent()
          : Value(deletedBy),
      replyTo: replyTo == null && nullToAbsent
          ? const Value.absent()
          : Value(replyTo),
      forwarded: Value(forwarded),
      poll: Value(poll),
      contact: Value(contact),
      photoGroup: photoGroup == null && nullToAbsent
          ? const Value.absent()
          : Value(photoGroup),
      extra: extra == null && nullToAbsent
          ? const Value.absent()
          : Value(extra),
    );
  }

  factory StoredMessageRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredMessageRow(
      id: serializer.fromJson<String>(json['id']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      senderId: serializer.fromJson<String>(json['senderId']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      body: serializer.fromJson<String>(json['body']),
      bodyFolded: serializer.fromJson<String>(json['bodyFolded']),
      editedAt: serializer.fromJson<int?>(json['editedAt']),
      deleted: serializer.fromJson<String?>(json['deleted']),
      deletedBy: serializer.fromJson<String?>(json['deletedBy']),
      replyTo: serializer.fromJson<String?>(json['replyTo']),
      forwarded: serializer.fromJson<bool>(json['forwarded']),
      poll: serializer.fromJson<bool>(json['poll']),
      contact: serializer.fromJson<bool>(json['contact']),
      photoGroup: serializer.fromJson<String?>(json['photoGroup']),
      extra: serializer.fromJson<String?>(json['extra']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'conversationId': serializer.toJson<String>(conversationId),
      'senderId': serializer.toJson<String>(senderId),
      'createdAt': serializer.toJson<int>(createdAt),
      'body': serializer.toJson<String>(body),
      'bodyFolded': serializer.toJson<String>(bodyFolded),
      'editedAt': serializer.toJson<int?>(editedAt),
      'deleted': serializer.toJson<String?>(deleted),
      'deletedBy': serializer.toJson<String?>(deletedBy),
      'replyTo': serializer.toJson<String?>(replyTo),
      'forwarded': serializer.toJson<bool>(forwarded),
      'poll': serializer.toJson<bool>(poll),
      'contact': serializer.toJson<bool>(contact),
      'photoGroup': serializer.toJson<String?>(photoGroup),
      'extra': serializer.toJson<String?>(extra),
    };
  }

  StoredMessageRow copyWith({
    String? id,
    String? conversationId,
    String? senderId,
    int? createdAt,
    String? body,
    String? bodyFolded,
    Value<int?> editedAt = const Value.absent(),
    Value<String?> deleted = const Value.absent(),
    Value<String?> deletedBy = const Value.absent(),
    Value<String?> replyTo = const Value.absent(),
    bool? forwarded,
    bool? poll,
    bool? contact,
    Value<String?> photoGroup = const Value.absent(),
    Value<String?> extra = const Value.absent(),
  }) => StoredMessageRow(
    id: id ?? this.id,
    conversationId: conversationId ?? this.conversationId,
    senderId: senderId ?? this.senderId,
    createdAt: createdAt ?? this.createdAt,
    body: body ?? this.body,
    bodyFolded: bodyFolded ?? this.bodyFolded,
    editedAt: editedAt.present ? editedAt.value : this.editedAt,
    deleted: deleted.present ? deleted.value : this.deleted,
    deletedBy: deletedBy.present ? deletedBy.value : this.deletedBy,
    replyTo: replyTo.present ? replyTo.value : this.replyTo,
    forwarded: forwarded ?? this.forwarded,
    poll: poll ?? this.poll,
    contact: contact ?? this.contact,
    photoGroup: photoGroup.present ? photoGroup.value : this.photoGroup,
    extra: extra.present ? extra.value : this.extra,
  );
  StoredMessageRow copyWithCompanion(MessagesCompanion data) {
    return StoredMessageRow(
      id: data.id.present ? data.id.value : this.id,
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      senderId: data.senderId.present ? data.senderId.value : this.senderId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      body: data.body.present ? data.body.value : this.body,
      bodyFolded: data.bodyFolded.present
          ? data.bodyFolded.value
          : this.bodyFolded,
      editedAt: data.editedAt.present ? data.editedAt.value : this.editedAt,
      deleted: data.deleted.present ? data.deleted.value : this.deleted,
      deletedBy: data.deletedBy.present ? data.deletedBy.value : this.deletedBy,
      replyTo: data.replyTo.present ? data.replyTo.value : this.replyTo,
      forwarded: data.forwarded.present ? data.forwarded.value : this.forwarded,
      poll: data.poll.present ? data.poll.value : this.poll,
      contact: data.contact.present ? data.contact.value : this.contact,
      photoGroup: data.photoGroup.present
          ? data.photoGroup.value
          : this.photoGroup,
      extra: data.extra.present ? data.extra.value : this.extra,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredMessageRow(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('senderId: $senderId, ')
          ..write('createdAt: $createdAt, ')
          ..write('body: $body, ')
          ..write('bodyFolded: $bodyFolded, ')
          ..write('editedAt: $editedAt, ')
          ..write('deleted: $deleted, ')
          ..write('deletedBy: $deletedBy, ')
          ..write('replyTo: $replyTo, ')
          ..write('forwarded: $forwarded, ')
          ..write('poll: $poll, ')
          ..write('contact: $contact, ')
          ..write('photoGroup: $photoGroup, ')
          ..write('extra: $extra')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    conversationId,
    senderId,
    createdAt,
    body,
    bodyFolded,
    editedAt,
    deleted,
    deletedBy,
    replyTo,
    forwarded,
    poll,
    contact,
    photoGroup,
    extra,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredMessageRow &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.senderId == this.senderId &&
          other.createdAt == this.createdAt &&
          other.body == this.body &&
          other.bodyFolded == this.bodyFolded &&
          other.editedAt == this.editedAt &&
          other.deleted == this.deleted &&
          other.deletedBy == this.deletedBy &&
          other.replyTo == this.replyTo &&
          other.forwarded == this.forwarded &&
          other.poll == this.poll &&
          other.contact == this.contact &&
          other.photoGroup == this.photoGroup &&
          other.extra == this.extra);
}

class MessagesCompanion extends UpdateCompanion<StoredMessageRow> {
  final Value<String> id;
  final Value<String> conversationId;
  final Value<String> senderId;
  final Value<int> createdAt;
  final Value<String> body;
  final Value<String> bodyFolded;
  final Value<int?> editedAt;
  final Value<String?> deleted;
  final Value<String?> deletedBy;
  final Value<String?> replyTo;
  final Value<bool> forwarded;
  final Value<bool> poll;
  final Value<bool> contact;
  final Value<String?> photoGroup;
  final Value<String?> extra;
  final Value<int> rowid;
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.senderId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.body = const Value.absent(),
    this.bodyFolded = const Value.absent(),
    this.editedAt = const Value.absent(),
    this.deleted = const Value.absent(),
    this.deletedBy = const Value.absent(),
    this.replyTo = const Value.absent(),
    this.forwarded = const Value.absent(),
    this.poll = const Value.absent(),
    this.contact = const Value.absent(),
    this.photoGroup = const Value.absent(),
    this.extra = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagesCompanion.insert({
    required String id,
    required String conversationId,
    required String senderId,
    required int createdAt,
    required String body,
    required String bodyFolded,
    this.editedAt = const Value.absent(),
    this.deleted = const Value.absent(),
    this.deletedBy = const Value.absent(),
    this.replyTo = const Value.absent(),
    this.forwarded = const Value.absent(),
    this.poll = const Value.absent(),
    this.contact = const Value.absent(),
    this.photoGroup = const Value.absent(),
    this.extra = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       conversationId = Value(conversationId),
       senderId = Value(senderId),
       createdAt = Value(createdAt),
       body = Value(body),
       bodyFolded = Value(bodyFolded);
  static Insertable<StoredMessageRow> custom({
    Expression<String>? id,
    Expression<String>? conversationId,
    Expression<String>? senderId,
    Expression<int>? createdAt,
    Expression<String>? body,
    Expression<String>? bodyFolded,
    Expression<int>? editedAt,
    Expression<String>? deleted,
    Expression<String>? deletedBy,
    Expression<String>? replyTo,
    Expression<bool>? forwarded,
    Expression<bool>? poll,
    Expression<bool>? contact,
    Expression<String>? photoGroup,
    Expression<String>? extra,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (senderId != null) 'sender_id': senderId,
      if (createdAt != null) 'created_at': createdAt,
      if (body != null) 'body': body,
      if (bodyFolded != null) 'body_folded': bodyFolded,
      if (editedAt != null) 'edited_at': editedAt,
      if (deleted != null) 'deleted': deleted,
      if (deletedBy != null) 'deleted_by': deletedBy,
      if (replyTo != null) 'reply_to': replyTo,
      if (forwarded != null) 'forwarded': forwarded,
      if (poll != null) 'poll': poll,
      if (contact != null) 'contact': contact,
      if (photoGroup != null) 'photo_group': photoGroup,
      if (extra != null) 'extra': extra,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagesCompanion copyWith({
    Value<String>? id,
    Value<String>? conversationId,
    Value<String>? senderId,
    Value<int>? createdAt,
    Value<String>? body,
    Value<String>? bodyFolded,
    Value<int?>? editedAt,
    Value<String?>? deleted,
    Value<String?>? deletedBy,
    Value<String?>? replyTo,
    Value<bool>? forwarded,
    Value<bool>? poll,
    Value<bool>? contact,
    Value<String?>? photoGroup,
    Value<String?>? extra,
    Value<int>? rowid,
  }) {
    return MessagesCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      senderId: senderId ?? this.senderId,
      createdAt: createdAt ?? this.createdAt,
      body: body ?? this.body,
      bodyFolded: bodyFolded ?? this.bodyFolded,
      editedAt: editedAt ?? this.editedAt,
      deleted: deleted ?? this.deleted,
      deletedBy: deletedBy ?? this.deletedBy,
      replyTo: replyTo ?? this.replyTo,
      forwarded: forwarded ?? this.forwarded,
      poll: poll ?? this.poll,
      contact: contact ?? this.contact,
      photoGroup: photoGroup ?? this.photoGroup,
      extra: extra ?? this.extra,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (senderId.present) {
      map['sender_id'] = Variable<String>(senderId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (bodyFolded.present) {
      map['body_folded'] = Variable<String>(bodyFolded.value);
    }
    if (editedAt.present) {
      map['edited_at'] = Variable<int>(editedAt.value);
    }
    if (deleted.present) {
      map['deleted'] = Variable<String>(deleted.value);
    }
    if (deletedBy.present) {
      map['deleted_by'] = Variable<String>(deletedBy.value);
    }
    if (replyTo.present) {
      map['reply_to'] = Variable<String>(replyTo.value);
    }
    if (forwarded.present) {
      map['forwarded'] = Variable<bool>(forwarded.value);
    }
    if (poll.present) {
      map['poll'] = Variable<bool>(poll.value);
    }
    if (contact.present) {
      map['contact'] = Variable<bool>(contact.value);
    }
    if (photoGroup.present) {
      map['photo_group'] = Variable<String>(photoGroup.value);
    }
    if (extra.present) {
      map['extra'] = Variable<String>(extra.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('senderId: $senderId, ')
          ..write('createdAt: $createdAt, ')
          ..write('body: $body, ')
          ..write('bodyFolded: $bodyFolded, ')
          ..write('editedAt: $editedAt, ')
          ..write('deleted: $deleted, ')
          ..write('deletedBy: $deletedBy, ')
          ..write('replyTo: $replyTo, ')
          ..write('forwarded: $forwarded, ')
          ..write('poll: $poll, ')
          ..write('contact: $contact, ')
          ..write('photoGroup: $photoGroup, ')
          ..write('extra: $extra, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConversationsTable extends Conversations
    with TableInfo<$ConversationsTable, StoredConversationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _jsonMeta = const VerificationMeta('json');
  @override
  late final GeneratedColumn<String> json = GeneratedColumn<String>(
    'json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortAtMeta = const VerificationMeta('sortAt');
  @override
  late final GeneratedColumn<int> sortAt = GeneratedColumn<int>(
    'sort_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, json, sortAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversations';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredConversationRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('json')) {
      context.handle(
        _jsonMeta,
        json.isAcceptableOrUnknown(data['json']!, _jsonMeta),
      );
    } else if (isInserting) {
      context.missing(_jsonMeta);
    }
    if (data.containsKey('sort_at')) {
      context.handle(
        _sortAtMeta,
        sortAt.isAcceptableOrUnknown(data['sort_at']!, _sortAtMeta),
      );
    } else if (isInserting) {
      context.missing(_sortAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  StoredConversationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredConversationRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      json: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}json'],
      )!,
      sortAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_at'],
      )!,
    );
  }

  @override
  $ConversationsTable createAlias(String alias) {
    return $ConversationsTable(attachedDatabase, alias);
  }
}

class StoredConversationRow extends DataClass
    implements Insertable<StoredConversationRow> {
  final String id;
  final String json;
  final int sortAt;
  const StoredConversationRow({
    required this.id,
    required this.json,
    required this.sortAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['json'] = Variable<String>(json);
    map['sort_at'] = Variable<int>(sortAt);
    return map;
  }

  ConversationsCompanion toCompanion(bool nullToAbsent) {
    return ConversationsCompanion(
      id: Value(id),
      json: Value(json),
      sortAt: Value(sortAt),
    );
  }

  factory StoredConversationRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredConversationRow(
      id: serializer.fromJson<String>(json['id']),
      json: serializer.fromJson<String>(json['json']),
      sortAt: serializer.fromJson<int>(json['sortAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'json': serializer.toJson<String>(json),
      'sortAt': serializer.toJson<int>(sortAt),
    };
  }

  StoredConversationRow copyWith({String? id, String? json, int? sortAt}) =>
      StoredConversationRow(
        id: id ?? this.id,
        json: json ?? this.json,
        sortAt: sortAt ?? this.sortAt,
      );
  StoredConversationRow copyWithCompanion(ConversationsCompanion data) {
    return StoredConversationRow(
      id: data.id.present ? data.id.value : this.id,
      json: data.json.present ? data.json.value : this.json,
      sortAt: data.sortAt.present ? data.sortAt.value : this.sortAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredConversationRow(')
          ..write('id: $id, ')
          ..write('json: $json, ')
          ..write('sortAt: $sortAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, json, sortAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredConversationRow &&
          other.id == this.id &&
          other.json == this.json &&
          other.sortAt == this.sortAt);
}

class ConversationsCompanion extends UpdateCompanion<StoredConversationRow> {
  final Value<String> id;
  final Value<String> json;
  final Value<int> sortAt;
  final Value<int> rowid;
  const ConversationsCompanion({
    this.id = const Value.absent(),
    this.json = const Value.absent(),
    this.sortAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationsCompanion.insert({
    required String id,
    required String json,
    required int sortAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       json = Value(json),
       sortAt = Value(sortAt);
  static Insertable<StoredConversationRow> custom({
    Expression<String>? id,
    Expression<String>? json,
    Expression<int>? sortAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (json != null) 'json': json,
      if (sortAt != null) 'sort_at': sortAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationsCompanion copyWith({
    Value<String>? id,
    Value<String>? json,
    Value<int>? sortAt,
    Value<int>? rowid,
  }) {
    return ConversationsCompanion(
      id: id ?? this.id,
      json: json ?? this.json,
      sortAt: sortAt ?? this.sortAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (json.present) {
      map['json'] = Variable<String>(json.value);
    }
    if (sortAt.present) {
      map['sort_at'] = Variable<int>(sortAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationsCompanion(')
          ..write('id: $id, ')
          ..write('json: $json, ')
          ..write('sortAt: $sortAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncStatesTable extends SyncStates
    with TableInfo<$SyncStatesTable, StoredSyncRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _newestAtMeta = const VerificationMeta(
    'newestAt',
  );
  @override
  late final GeneratedColumn<int> newestAt = GeneratedColumn<int>(
    'newest_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contiguousFromMeta = const VerificationMeta(
    'contiguousFrom',
  );
  @override
  late final GeneratedColumn<int> contiguousFrom = GeneratedColumn<int>(
    'contiguous_from',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _completeMeta = const VerificationMeta(
    'complete',
  );
  @override
  late final GeneratedColumn<bool> complete = GeneratedColumn<bool>(
    'complete',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("complete" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [
    conversationId,
    newestAt,
    contiguousFrom,
    complete,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_state';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredSyncRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('newest_at')) {
      context.handle(
        _newestAtMeta,
        newestAt.isAcceptableOrUnknown(data['newest_at']!, _newestAtMeta),
      );
    }
    if (data.containsKey('contiguous_from')) {
      context.handle(
        _contiguousFromMeta,
        contiguousFrom.isAcceptableOrUnknown(
          data['contiguous_from']!,
          _contiguousFromMeta,
        ),
      );
    }
    if (data.containsKey('complete')) {
      context.handle(
        _completeMeta,
        complete.isAcceptableOrUnknown(data['complete']!, _completeMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId};
  @override
  StoredSyncRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredSyncRow(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      newestAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}newest_at'],
      ),
      contiguousFrom: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}contiguous_from'],
      ),
      complete: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}complete'],
      )!,
    );
  }

  @override
  $SyncStatesTable createAlias(String alias) {
    return $SyncStatesTable(attachedDatabase, alias);
  }
}

class StoredSyncRow extends DataClass implements Insertable<StoredSyncRow> {
  final String conversationId;
  final int? newestAt;
  final int? contiguousFrom;
  final bool complete;
  const StoredSyncRow({
    required this.conversationId,
    this.newestAt,
    this.contiguousFrom,
    required this.complete,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    if (!nullToAbsent || newestAt != null) {
      map['newest_at'] = Variable<int>(newestAt);
    }
    if (!nullToAbsent || contiguousFrom != null) {
      map['contiguous_from'] = Variable<int>(contiguousFrom);
    }
    map['complete'] = Variable<bool>(complete);
    return map;
  }

  SyncStatesCompanion toCompanion(bool nullToAbsent) {
    return SyncStatesCompanion(
      conversationId: Value(conversationId),
      newestAt: newestAt == null && nullToAbsent
          ? const Value.absent()
          : Value(newestAt),
      contiguousFrom: contiguousFrom == null && nullToAbsent
          ? const Value.absent()
          : Value(contiguousFrom),
      complete: Value(complete),
    );
  }

  factory StoredSyncRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredSyncRow(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      newestAt: serializer.fromJson<int?>(json['newestAt']),
      contiguousFrom: serializer.fromJson<int?>(json['contiguousFrom']),
      complete: serializer.fromJson<bool>(json['complete']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'newestAt': serializer.toJson<int?>(newestAt),
      'contiguousFrom': serializer.toJson<int?>(contiguousFrom),
      'complete': serializer.toJson<bool>(complete),
    };
  }

  StoredSyncRow copyWith({
    String? conversationId,
    Value<int?> newestAt = const Value.absent(),
    Value<int?> contiguousFrom = const Value.absent(),
    bool? complete,
  }) => StoredSyncRow(
    conversationId: conversationId ?? this.conversationId,
    newestAt: newestAt.present ? newestAt.value : this.newestAt,
    contiguousFrom: contiguousFrom.present
        ? contiguousFrom.value
        : this.contiguousFrom,
    complete: complete ?? this.complete,
  );
  StoredSyncRow copyWithCompanion(SyncStatesCompanion data) {
    return StoredSyncRow(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      newestAt: data.newestAt.present ? data.newestAt.value : this.newestAt,
      contiguousFrom: data.contiguousFrom.present
          ? data.contiguousFrom.value
          : this.contiguousFrom,
      complete: data.complete.present ? data.complete.value : this.complete,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredSyncRow(')
          ..write('conversationId: $conversationId, ')
          ..write('newestAt: $newestAt, ')
          ..write('contiguousFrom: $contiguousFrom, ')
          ..write('complete: $complete')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(conversationId, newestAt, contiguousFrom, complete);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredSyncRow &&
          other.conversationId == this.conversationId &&
          other.newestAt == this.newestAt &&
          other.contiguousFrom == this.contiguousFrom &&
          other.complete == this.complete);
}

class SyncStatesCompanion extends UpdateCompanion<StoredSyncRow> {
  final Value<String> conversationId;
  final Value<int?> newestAt;
  final Value<int?> contiguousFrom;
  final Value<bool> complete;
  final Value<int> rowid;
  const SyncStatesCompanion({
    this.conversationId = const Value.absent(),
    this.newestAt = const Value.absent(),
    this.contiguousFrom = const Value.absent(),
    this.complete = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncStatesCompanion.insert({
    required String conversationId,
    this.newestAt = const Value.absent(),
    this.contiguousFrom = const Value.absent(),
    this.complete = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId);
  static Insertable<StoredSyncRow> custom({
    Expression<String>? conversationId,
    Expression<int>? newestAt,
    Expression<int>? contiguousFrom,
    Expression<bool>? complete,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (newestAt != null) 'newest_at': newestAt,
      if (contiguousFrom != null) 'contiguous_from': contiguousFrom,
      if (complete != null) 'complete': complete,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncStatesCompanion copyWith({
    Value<String>? conversationId,
    Value<int?>? newestAt,
    Value<int?>? contiguousFrom,
    Value<bool>? complete,
    Value<int>? rowid,
  }) {
    return SyncStatesCompanion(
      conversationId: conversationId ?? this.conversationId,
      newestAt: newestAt ?? this.newestAt,
      contiguousFrom: contiguousFrom ?? this.contiguousFrom,
      complete: complete ?? this.complete,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (newestAt.present) {
      map['newest_at'] = Variable<int>(newestAt.value);
    }
    if (contiguousFrom.present) {
      map['contiguous_from'] = Variable<int>(contiguousFrom.value);
    }
    if (complete.present) {
      map['complete'] = Variable<bool>(complete.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncStatesCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('newestAt: $newestAt, ')
          ..write('contiguousFrom: $contiguousFrom, ')
          ..write('complete: $complete, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MetaTable extends Meta with TableInfo<$MetaTable, StoredMetaRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MetaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'meta';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredMetaRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  StoredMetaRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredMetaRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $MetaTable createAlias(String alias) {
    return $MetaTable(attachedDatabase, alias);
  }
}

class StoredMetaRow extends DataClass implements Insertable<StoredMetaRow> {
  final String key;
  final String value;
  const StoredMetaRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  MetaCompanion toCompanion(bool nullToAbsent) {
    return MetaCompanion(key: Value(key), value: Value(value));
  }

  factory StoredMetaRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredMetaRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  StoredMetaRow copyWith({String? key, String? value}) =>
      StoredMetaRow(key: key ?? this.key, value: value ?? this.value);
  StoredMetaRow copyWithCompanion(MetaCompanion data) {
    return StoredMetaRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredMetaRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredMetaRow &&
          other.key == this.key &&
          other.value == this.value);
}

class MetaCompanion extends UpdateCompanion<StoredMetaRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const MetaCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MetaCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<StoredMetaRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MetaCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return MetaCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MetaCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ReadMarksTable extends ReadMarks
    with TableInfo<$ReadMarksTable, StoredReadMarkRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReadMarksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _conversationIdMeta = const VerificationMeta(
    'conversationId',
  );
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sharesMeta = const VerificationMeta('shares');
  @override
  late final GeneratedColumn<bool> shares = GeneratedColumn<bool>(
    'shares',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("shares" IN (0, 1))',
    ),
  );
  static const VerificationMeta _readAtMeta = const VerificationMeta('readAt');
  @override
  late final GeneratedColumn<int> readAt = GeneratedColumn<int>(
    'read_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _deliveredAtMeta = const VerificationMeta(
    'deliveredAt',
  );
  @override
  late final GeneratedColumn<int> deliveredAt = GeneratedColumn<int>(
    'delivered_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    conversationId,
    userId,
    shares,
    readAt,
    deliveredAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'read_marks';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredReadMarkRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(
          data['conversation_id']!,
          _conversationIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('shares')) {
      context.handle(
        _sharesMeta,
        shares.isAcceptableOrUnknown(data['shares']!, _sharesMeta),
      );
    } else if (isInserting) {
      context.missing(_sharesMeta);
    }
    if (data.containsKey('read_at')) {
      context.handle(
        _readAtMeta,
        readAt.isAcceptableOrUnknown(data['read_at']!, _readAtMeta),
      );
    }
    if (data.containsKey('delivered_at')) {
      context.handle(
        _deliveredAtMeta,
        deliveredAt.isAcceptableOrUnknown(
          data['delivered_at']!,
          _deliveredAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {conversationId, userId};
  @override
  StoredReadMarkRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredReadMarkRow(
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      shares: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}shares'],
      )!,
      readAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}read_at'],
      ),
      deliveredAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}delivered_at'],
      ),
    );
  }

  @override
  $ReadMarksTable createAlias(String alias) {
    return $ReadMarksTable(attachedDatabase, alias);
  }
}

class StoredReadMarkRow extends DataClass
    implements Insertable<StoredReadMarkRow> {
  final String conversationId;
  final String userId;
  final bool shares;
  final int? readAt;
  final int? deliveredAt;
  const StoredReadMarkRow({
    required this.conversationId,
    required this.userId,
    required this.shares,
    this.readAt,
    this.deliveredAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['conversation_id'] = Variable<String>(conversationId);
    map['user_id'] = Variable<String>(userId);
    map['shares'] = Variable<bool>(shares);
    if (!nullToAbsent || readAt != null) {
      map['read_at'] = Variable<int>(readAt);
    }
    if (!nullToAbsent || deliveredAt != null) {
      map['delivered_at'] = Variable<int>(deliveredAt);
    }
    return map;
  }

  ReadMarksCompanion toCompanion(bool nullToAbsent) {
    return ReadMarksCompanion(
      conversationId: Value(conversationId),
      userId: Value(userId),
      shares: Value(shares),
      readAt: readAt == null && nullToAbsent
          ? const Value.absent()
          : Value(readAt),
      deliveredAt: deliveredAt == null && nullToAbsent
          ? const Value.absent()
          : Value(deliveredAt),
    );
  }

  factory StoredReadMarkRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredReadMarkRow(
      conversationId: serializer.fromJson<String>(json['conversationId']),
      userId: serializer.fromJson<String>(json['userId']),
      shares: serializer.fromJson<bool>(json['shares']),
      readAt: serializer.fromJson<int?>(json['readAt']),
      deliveredAt: serializer.fromJson<int?>(json['deliveredAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'conversationId': serializer.toJson<String>(conversationId),
      'userId': serializer.toJson<String>(userId),
      'shares': serializer.toJson<bool>(shares),
      'readAt': serializer.toJson<int?>(readAt),
      'deliveredAt': serializer.toJson<int?>(deliveredAt),
    };
  }

  StoredReadMarkRow copyWith({
    String? conversationId,
    String? userId,
    bool? shares,
    Value<int?> readAt = const Value.absent(),
    Value<int?> deliveredAt = const Value.absent(),
  }) => StoredReadMarkRow(
    conversationId: conversationId ?? this.conversationId,
    userId: userId ?? this.userId,
    shares: shares ?? this.shares,
    readAt: readAt.present ? readAt.value : this.readAt,
    deliveredAt: deliveredAt.present ? deliveredAt.value : this.deliveredAt,
  );
  StoredReadMarkRow copyWithCompanion(ReadMarksCompanion data) {
    return StoredReadMarkRow(
      conversationId: data.conversationId.present
          ? data.conversationId.value
          : this.conversationId,
      userId: data.userId.present ? data.userId.value : this.userId,
      shares: data.shares.present ? data.shares.value : this.shares,
      readAt: data.readAt.present ? data.readAt.value : this.readAt,
      deliveredAt: data.deliveredAt.present
          ? data.deliveredAt.value
          : this.deliveredAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredReadMarkRow(')
          ..write('conversationId: $conversationId, ')
          ..write('userId: $userId, ')
          ..write('shares: $shares, ')
          ..write('readAt: $readAt, ')
          ..write('deliveredAt: $deliveredAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(conversationId, userId, shares, readAt, deliveredAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredReadMarkRow &&
          other.conversationId == this.conversationId &&
          other.userId == this.userId &&
          other.shares == this.shares &&
          other.readAt == this.readAt &&
          other.deliveredAt == this.deliveredAt);
}

class ReadMarksCompanion extends UpdateCompanion<StoredReadMarkRow> {
  final Value<String> conversationId;
  final Value<String> userId;
  final Value<bool> shares;
  final Value<int?> readAt;
  final Value<int?> deliveredAt;
  final Value<int> rowid;
  const ReadMarksCompanion({
    this.conversationId = const Value.absent(),
    this.userId = const Value.absent(),
    this.shares = const Value.absent(),
    this.readAt = const Value.absent(),
    this.deliveredAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReadMarksCompanion.insert({
    required String conversationId,
    required String userId,
    required bool shares,
    this.readAt = const Value.absent(),
    this.deliveredAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : conversationId = Value(conversationId),
       userId = Value(userId),
       shares = Value(shares);
  static Insertable<StoredReadMarkRow> custom({
    Expression<String>? conversationId,
    Expression<String>? userId,
    Expression<bool>? shares,
    Expression<int>? readAt,
    Expression<int>? deliveredAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (conversationId != null) 'conversation_id': conversationId,
      if (userId != null) 'user_id': userId,
      if (shares != null) 'shares': shares,
      if (readAt != null) 'read_at': readAt,
      if (deliveredAt != null) 'delivered_at': deliveredAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReadMarksCompanion copyWith({
    Value<String>? conversationId,
    Value<String>? userId,
    Value<bool>? shares,
    Value<int?>? readAt,
    Value<int?>? deliveredAt,
    Value<int>? rowid,
  }) {
    return ReadMarksCompanion(
      conversationId: conversationId ?? this.conversationId,
      userId: userId ?? this.userId,
      shares: shares ?? this.shares,
      readAt: readAt ?? this.readAt,
      deliveredAt: deliveredAt ?? this.deliveredAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (shares.present) {
      map['shares'] = Variable<bool>(shares.value);
    }
    if (readAt.present) {
      map['read_at'] = Variable<int>(readAt.value);
    }
    if (deliveredAt.present) {
      map['delivered_at'] = Variable<int>(deliveredAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReadMarksCompanion(')
          ..write('conversationId: $conversationId, ')
          ..write('userId: $userId, ')
          ..write('shares: $shares, ')
          ..write('readAt: $readAt, ')
          ..write('deliveredAt: $deliveredAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OlmSessionsTable extends OlmSessions
    with TableInfo<$OlmSessionsTable, StoredOlmSessionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OlmSessionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<String> sessionId = GeneratedColumn<String>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _peerUserIdMeta = const VerificationMeta(
    'peerUserId',
  );
  @override
  late final GeneratedColumn<String> peerUserId = GeneratedColumn<String>(
    'peer_user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _peerIdentityKeyMeta = const VerificationMeta(
    'peerIdentityKey',
  );
  @override
  late final GeneratedColumn<String> peerIdentityKey = GeneratedColumn<String>(
    'peer_identity_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pickleMeta = const VerificationMeta('pickle');
  @override
  late final GeneratedColumn<String> pickle = GeneratedColumn<String>(
    'pickle',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastUsedAtMeta = const VerificationMeta(
    'lastUsedAt',
  );
  @override
  late final GeneratedColumn<int> lastUsedAt = GeneratedColumn<int>(
    'last_used_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    sessionId,
    peerUserId,
    peerIdentityKey,
    pickle,
    lastUsedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'olm_sessions';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredOlmSessionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('peer_user_id')) {
      context.handle(
        _peerUserIdMeta,
        peerUserId.isAcceptableOrUnknown(
          data['peer_user_id']!,
          _peerUserIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_peerUserIdMeta);
    }
    if (data.containsKey('peer_identity_key')) {
      context.handle(
        _peerIdentityKeyMeta,
        peerIdentityKey.isAcceptableOrUnknown(
          data['peer_identity_key']!,
          _peerIdentityKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_peerIdentityKeyMeta);
    }
    if (data.containsKey('pickle')) {
      context.handle(
        _pickleMeta,
        pickle.isAcceptableOrUnknown(data['pickle']!, _pickleMeta),
      );
    } else if (isInserting) {
      context.missing(_pickleMeta);
    }
    if (data.containsKey('last_used_at')) {
      context.handle(
        _lastUsedAtMeta,
        lastUsedAt.isAcceptableOrUnknown(
          data['last_used_at']!,
          _lastUsedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_lastUsedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {sessionId};
  @override
  StoredOlmSessionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredOlmSessionRow(
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session_id'],
      )!,
      peerUserId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_user_id'],
      )!,
      peerIdentityKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}peer_identity_key'],
      )!,
      pickle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pickle'],
      )!,
      lastUsedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_used_at'],
      )!,
    );
  }

  @override
  $OlmSessionsTable createAlias(String alias) {
    return $OlmSessionsTable(attachedDatabase, alias);
  }
}

class StoredOlmSessionRow extends DataClass
    implements Insertable<StoredOlmSessionRow> {
  final String sessionId;
  final String peerUserId;
  final String peerIdentityKey;
  final String pickle;

  /// Microseconds since epoch.
  final int lastUsedAt;
  const StoredOlmSessionRow({
    required this.sessionId,
    required this.peerUserId,
    required this.peerIdentityKey,
    required this.pickle,
    required this.lastUsedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['session_id'] = Variable<String>(sessionId);
    map['peer_user_id'] = Variable<String>(peerUserId);
    map['peer_identity_key'] = Variable<String>(peerIdentityKey);
    map['pickle'] = Variable<String>(pickle);
    map['last_used_at'] = Variable<int>(lastUsedAt);
    return map;
  }

  OlmSessionsCompanion toCompanion(bool nullToAbsent) {
    return OlmSessionsCompanion(
      sessionId: Value(sessionId),
      peerUserId: Value(peerUserId),
      peerIdentityKey: Value(peerIdentityKey),
      pickle: Value(pickle),
      lastUsedAt: Value(lastUsedAt),
    );
  }

  factory StoredOlmSessionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredOlmSessionRow(
      sessionId: serializer.fromJson<String>(json['sessionId']),
      peerUserId: serializer.fromJson<String>(json['peerUserId']),
      peerIdentityKey: serializer.fromJson<String>(json['peerIdentityKey']),
      pickle: serializer.fromJson<String>(json['pickle']),
      lastUsedAt: serializer.fromJson<int>(json['lastUsedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'sessionId': serializer.toJson<String>(sessionId),
      'peerUserId': serializer.toJson<String>(peerUserId),
      'peerIdentityKey': serializer.toJson<String>(peerIdentityKey),
      'pickle': serializer.toJson<String>(pickle),
      'lastUsedAt': serializer.toJson<int>(lastUsedAt),
    };
  }

  StoredOlmSessionRow copyWith({
    String? sessionId,
    String? peerUserId,
    String? peerIdentityKey,
    String? pickle,
    int? lastUsedAt,
  }) => StoredOlmSessionRow(
    sessionId: sessionId ?? this.sessionId,
    peerUserId: peerUserId ?? this.peerUserId,
    peerIdentityKey: peerIdentityKey ?? this.peerIdentityKey,
    pickle: pickle ?? this.pickle,
    lastUsedAt: lastUsedAt ?? this.lastUsedAt,
  );
  StoredOlmSessionRow copyWithCompanion(OlmSessionsCompanion data) {
    return StoredOlmSessionRow(
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      peerUserId: data.peerUserId.present
          ? data.peerUserId.value
          : this.peerUserId,
      peerIdentityKey: data.peerIdentityKey.present
          ? data.peerIdentityKey.value
          : this.peerIdentityKey,
      pickle: data.pickle.present ? data.pickle.value : this.pickle,
      lastUsedAt: data.lastUsedAt.present
          ? data.lastUsedAt.value
          : this.lastUsedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredOlmSessionRow(')
          ..write('sessionId: $sessionId, ')
          ..write('peerUserId: $peerUserId, ')
          ..write('peerIdentityKey: $peerIdentityKey, ')
          ..write('pickle: $pickle, ')
          ..write('lastUsedAt: $lastUsedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(sessionId, peerUserId, peerIdentityKey, pickle, lastUsedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredOlmSessionRow &&
          other.sessionId == this.sessionId &&
          other.peerUserId == this.peerUserId &&
          other.peerIdentityKey == this.peerIdentityKey &&
          other.pickle == this.pickle &&
          other.lastUsedAt == this.lastUsedAt);
}

class OlmSessionsCompanion extends UpdateCompanion<StoredOlmSessionRow> {
  final Value<String> sessionId;
  final Value<String> peerUserId;
  final Value<String> peerIdentityKey;
  final Value<String> pickle;
  final Value<int> lastUsedAt;
  final Value<int> rowid;
  const OlmSessionsCompanion({
    this.sessionId = const Value.absent(),
    this.peerUserId = const Value.absent(),
    this.peerIdentityKey = const Value.absent(),
    this.pickle = const Value.absent(),
    this.lastUsedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  OlmSessionsCompanion.insert({
    required String sessionId,
    required String peerUserId,
    required String peerIdentityKey,
    required String pickle,
    required int lastUsedAt,
    this.rowid = const Value.absent(),
  }) : sessionId = Value(sessionId),
       peerUserId = Value(peerUserId),
       peerIdentityKey = Value(peerIdentityKey),
       pickle = Value(pickle),
       lastUsedAt = Value(lastUsedAt);
  static Insertable<StoredOlmSessionRow> custom({
    Expression<String>? sessionId,
    Expression<String>? peerUserId,
    Expression<String>? peerIdentityKey,
    Expression<String>? pickle,
    Expression<int>? lastUsedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (sessionId != null) 'session_id': sessionId,
      if (peerUserId != null) 'peer_user_id': peerUserId,
      if (peerIdentityKey != null) 'peer_identity_key': peerIdentityKey,
      if (pickle != null) 'pickle': pickle,
      if (lastUsedAt != null) 'last_used_at': lastUsedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  OlmSessionsCompanion copyWith({
    Value<String>? sessionId,
    Value<String>? peerUserId,
    Value<String>? peerIdentityKey,
    Value<String>? pickle,
    Value<int>? lastUsedAt,
    Value<int>? rowid,
  }) {
    return OlmSessionsCompanion(
      sessionId: sessionId ?? this.sessionId,
      peerUserId: peerUserId ?? this.peerUserId,
      peerIdentityKey: peerIdentityKey ?? this.peerIdentityKey,
      pickle: pickle ?? this.pickle,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (sessionId.present) {
      map['session_id'] = Variable<String>(sessionId.value);
    }
    if (peerUserId.present) {
      map['peer_user_id'] = Variable<String>(peerUserId.value);
    }
    if (peerIdentityKey.present) {
      map['peer_identity_key'] = Variable<String>(peerIdentityKey.value);
    }
    if (pickle.present) {
      map['pickle'] = Variable<String>(pickle.value);
    }
    if (lastUsedAt.present) {
      map['last_used_at'] = Variable<int>(lastUsedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OlmSessionsCompanion(')
          ..write('sessionId: $sessionId, ')
          ..write('peerUserId: $peerUserId, ')
          ..write('peerIdentityKey: $peerIdentityKey, ')
          ..write('pickle: $pickle, ')
          ..write('lastUsedAt: $lastUsedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SendQueueRowsTable extends SendQueueRows
    with TableInfo<$SendQueueRowsTable, StoredSendQueueRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SendQueueRowsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _recordMeta = const VerificationMeta('record');
  @override
  late final GeneratedColumn<String> record = GeneratedColumn<String>(
    'record',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ciphertextMeta = const VerificationMeta(
    'ciphertext',
  );
  @override
  late final GeneratedColumn<String> ciphertext = GeneratedColumn<String>(
    'ciphertext',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _olmTypeMeta = const VerificationMeta(
    'olmType',
  );
  @override
  late final GeneratedColumn<int> olmType = GeneratedColumn<int>(
    'olm_type',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    userId,
    id,
    position,
    record,
    ciphertext,
    olmType,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'send_queue';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredSendQueueRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('record')) {
      context.handle(
        _recordMeta,
        record.isAcceptableOrUnknown(data['record']!, _recordMeta),
      );
    } else if (isInserting) {
      context.missing(_recordMeta);
    }
    if (data.containsKey('ciphertext')) {
      context.handle(
        _ciphertextMeta,
        ciphertext.isAcceptableOrUnknown(data['ciphertext']!, _ciphertextMeta),
      );
    }
    if (data.containsKey('olm_type')) {
      context.handle(
        _olmTypeMeta,
        olmType.isAcceptableOrUnknown(data['olm_type']!, _olmTypeMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {userId, id};
  @override
  StoredSendQueueRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredSendQueueRow(
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
      record: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}record'],
      )!,
      ciphertext: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ciphertext'],
      ),
      olmType: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}olm_type'],
      ),
    );
  }

  @override
  $SendQueueRowsTable createAlias(String alias) {
    return $SendQueueRowsTable(attachedDatabase, alias);
  }
}

class StoredSendQueueRow extends DataClass
    implements Insertable<StoredSendQueueRow> {
  final String userId;
  final String id;
  final int position;
  final String record;
  final String? ciphertext;
  final int? olmType;
  const StoredSendQueueRow({
    required this.userId,
    required this.id,
    required this.position,
    required this.record,
    this.ciphertext,
    this.olmType,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['user_id'] = Variable<String>(userId);
    map['id'] = Variable<String>(id);
    map['position'] = Variable<int>(position);
    map['record'] = Variable<String>(record);
    if (!nullToAbsent || ciphertext != null) {
      map['ciphertext'] = Variable<String>(ciphertext);
    }
    if (!nullToAbsent || olmType != null) {
      map['olm_type'] = Variable<int>(olmType);
    }
    return map;
  }

  SendQueueRowsCompanion toCompanion(bool nullToAbsent) {
    return SendQueueRowsCompanion(
      userId: Value(userId),
      id: Value(id),
      position: Value(position),
      record: Value(record),
      ciphertext: ciphertext == null && nullToAbsent
          ? const Value.absent()
          : Value(ciphertext),
      olmType: olmType == null && nullToAbsent
          ? const Value.absent()
          : Value(olmType),
    );
  }

  factory StoredSendQueueRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredSendQueueRow(
      userId: serializer.fromJson<String>(json['userId']),
      id: serializer.fromJson<String>(json['id']),
      position: serializer.fromJson<int>(json['position']),
      record: serializer.fromJson<String>(json['record']),
      ciphertext: serializer.fromJson<String?>(json['ciphertext']),
      olmType: serializer.fromJson<int?>(json['olmType']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'userId': serializer.toJson<String>(userId),
      'id': serializer.toJson<String>(id),
      'position': serializer.toJson<int>(position),
      'record': serializer.toJson<String>(record),
      'ciphertext': serializer.toJson<String?>(ciphertext),
      'olmType': serializer.toJson<int?>(olmType),
    };
  }

  StoredSendQueueRow copyWith({
    String? userId,
    String? id,
    int? position,
    String? record,
    Value<String?> ciphertext = const Value.absent(),
    Value<int?> olmType = const Value.absent(),
  }) => StoredSendQueueRow(
    userId: userId ?? this.userId,
    id: id ?? this.id,
    position: position ?? this.position,
    record: record ?? this.record,
    ciphertext: ciphertext.present ? ciphertext.value : this.ciphertext,
    olmType: olmType.present ? olmType.value : this.olmType,
  );
  StoredSendQueueRow copyWithCompanion(SendQueueRowsCompanion data) {
    return StoredSendQueueRow(
      userId: data.userId.present ? data.userId.value : this.userId,
      id: data.id.present ? data.id.value : this.id,
      position: data.position.present ? data.position.value : this.position,
      record: data.record.present ? data.record.value : this.record,
      ciphertext: data.ciphertext.present
          ? data.ciphertext.value
          : this.ciphertext,
      olmType: data.olmType.present ? data.olmType.value : this.olmType,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredSendQueueRow(')
          ..write('userId: $userId, ')
          ..write('id: $id, ')
          ..write('position: $position, ')
          ..write('record: $record, ')
          ..write('ciphertext: $ciphertext, ')
          ..write('olmType: $olmType')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(userId, id, position, record, ciphertext, olmType);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredSendQueueRow &&
          other.userId == this.userId &&
          other.id == this.id &&
          other.position == this.position &&
          other.record == this.record &&
          other.ciphertext == this.ciphertext &&
          other.olmType == this.olmType);
}

class SendQueueRowsCompanion extends UpdateCompanion<StoredSendQueueRow> {
  final Value<String> userId;
  final Value<String> id;
  final Value<int> position;
  final Value<String> record;
  final Value<String?> ciphertext;
  final Value<int?> olmType;
  final Value<int> rowid;
  const SendQueueRowsCompanion({
    this.userId = const Value.absent(),
    this.id = const Value.absent(),
    this.position = const Value.absent(),
    this.record = const Value.absent(),
    this.ciphertext = const Value.absent(),
    this.olmType = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SendQueueRowsCompanion.insert({
    required String userId,
    required String id,
    required int position,
    required String record,
    this.ciphertext = const Value.absent(),
    this.olmType = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : userId = Value(userId),
       id = Value(id),
       position = Value(position),
       record = Value(record);
  static Insertable<StoredSendQueueRow> custom({
    Expression<String>? userId,
    Expression<String>? id,
    Expression<int>? position,
    Expression<String>? record,
    Expression<String>? ciphertext,
    Expression<int>? olmType,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (userId != null) 'user_id': userId,
      if (id != null) 'id': id,
      if (position != null) 'position': position,
      if (record != null) 'record': record,
      if (ciphertext != null) 'ciphertext': ciphertext,
      if (olmType != null) 'olm_type': olmType,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SendQueueRowsCompanion copyWith({
    Value<String>? userId,
    Value<String>? id,
    Value<int>? position,
    Value<String>? record,
    Value<String?>? ciphertext,
    Value<int?>? olmType,
    Value<int>? rowid,
  }) {
    return SendQueueRowsCompanion(
      userId: userId ?? this.userId,
      id: id ?? this.id,
      position: position ?? this.position,
      record: record ?? this.record,
      ciphertext: ciphertext ?? this.ciphertext,
      olmType: olmType ?? this.olmType,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (record.present) {
      map['record'] = Variable<String>(record.value);
    }
    if (ciphertext.present) {
      map['ciphertext'] = Variable<String>(ciphertext.value);
    }
    if (olmType.present) {
      map['olm_type'] = Variable<int>(olmType.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SendQueueRowsCompanion(')
          ..write('userId: $userId, ')
          ..write('id: $id, ')
          ..write('position: $position, ')
          ..write('record: $record, ')
          ..write('ciphertext: $ciphertext, ')
          ..write('olmType: $olmType, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ReactionPlainsTable extends ReactionPlains
    with TableInfo<$ReactionPlainsTable, StoredReactionPlainRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReactionPlainsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _messageIdMeta = const VerificationMeta(
    'messageId',
  );
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userIdMeta = const VerificationMeta('userId');
  @override
  late final GeneratedColumn<String> userId = GeneratedColumn<String>(
    'user_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sealedMeta = const VerificationMeta('sealed');
  @override
  late final GeneratedColumn<String> sealed = GeneratedColumn<String>(
    'sealed',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _emojiMeta = const VerificationMeta('emoji');
  @override
  late final GeneratedColumn<String> emoji = GeneratedColumn<String>(
    'emoji',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _savedAtMeta = const VerificationMeta(
    'savedAt',
  );
  @override
  late final GeneratedColumn<int> savedAt = GeneratedColumn<int>(
    'saved_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    messageId,
    userId,
    sealed,
    emoji,
    savedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'reaction_plains';
  @override
  VerificationContext validateIntegrity(
    Insertable<StoredReactionPlainRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('message_id')) {
      context.handle(
        _messageIdMeta,
        messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta),
      );
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('user_id')) {
      context.handle(
        _userIdMeta,
        userId.isAcceptableOrUnknown(data['user_id']!, _userIdMeta),
      );
    } else if (isInserting) {
      context.missing(_userIdMeta);
    }
    if (data.containsKey('sealed')) {
      context.handle(
        _sealedMeta,
        sealed.isAcceptableOrUnknown(data['sealed']!, _sealedMeta),
      );
    } else if (isInserting) {
      context.missing(_sealedMeta);
    }
    if (data.containsKey('emoji')) {
      context.handle(
        _emojiMeta,
        emoji.isAcceptableOrUnknown(data['emoji']!, _emojiMeta),
      );
    } else if (isInserting) {
      context.missing(_emojiMeta);
    }
    if (data.containsKey('saved_at')) {
      context.handle(
        _savedAtMeta,
        savedAt.isAcceptableOrUnknown(data['saved_at']!, _savedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_savedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {messageId, userId};
  @override
  StoredReactionPlainRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return StoredReactionPlainRow(
      messageId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message_id'],
      )!,
      userId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_id'],
      )!,
      sealed: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sealed'],
      )!,
      emoji: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}emoji'],
      )!,
      savedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}saved_at'],
      )!,
    );
  }

  @override
  $ReactionPlainsTable createAlias(String alias) {
    return $ReactionPlainsTable(attachedDatabase, alias);
  }
}

class StoredReactionPlainRow extends DataClass
    implements Insertable<StoredReactionPlainRow> {
  final String messageId;
  final String userId;
  final String sealed;
  final String emoji;
  final int savedAt;
  const StoredReactionPlainRow({
    required this.messageId,
    required this.userId,
    required this.sealed,
    required this.emoji,
    required this.savedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['message_id'] = Variable<String>(messageId);
    map['user_id'] = Variable<String>(userId);
    map['sealed'] = Variable<String>(sealed);
    map['emoji'] = Variable<String>(emoji);
    map['saved_at'] = Variable<int>(savedAt);
    return map;
  }

  ReactionPlainsCompanion toCompanion(bool nullToAbsent) {
    return ReactionPlainsCompanion(
      messageId: Value(messageId),
      userId: Value(userId),
      sealed: Value(sealed),
      emoji: Value(emoji),
      savedAt: Value(savedAt),
    );
  }

  factory StoredReactionPlainRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return StoredReactionPlainRow(
      messageId: serializer.fromJson<String>(json['messageId']),
      userId: serializer.fromJson<String>(json['userId']),
      sealed: serializer.fromJson<String>(json['sealed']),
      emoji: serializer.fromJson<String>(json['emoji']),
      savedAt: serializer.fromJson<int>(json['savedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'messageId': serializer.toJson<String>(messageId),
      'userId': serializer.toJson<String>(userId),
      'sealed': serializer.toJson<String>(sealed),
      'emoji': serializer.toJson<String>(emoji),
      'savedAt': serializer.toJson<int>(savedAt),
    };
  }

  StoredReactionPlainRow copyWith({
    String? messageId,
    String? userId,
    String? sealed,
    String? emoji,
    int? savedAt,
  }) => StoredReactionPlainRow(
    messageId: messageId ?? this.messageId,
    userId: userId ?? this.userId,
    sealed: sealed ?? this.sealed,
    emoji: emoji ?? this.emoji,
    savedAt: savedAt ?? this.savedAt,
  );
  StoredReactionPlainRow copyWithCompanion(ReactionPlainsCompanion data) {
    return StoredReactionPlainRow(
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      userId: data.userId.present ? data.userId.value : this.userId,
      sealed: data.sealed.present ? data.sealed.value : this.sealed,
      emoji: data.emoji.present ? data.emoji.value : this.emoji,
      savedAt: data.savedAt.present ? data.savedAt.value : this.savedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('StoredReactionPlainRow(')
          ..write('messageId: $messageId, ')
          ..write('userId: $userId, ')
          ..write('sealed: $sealed, ')
          ..write('emoji: $emoji, ')
          ..write('savedAt: $savedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(messageId, userId, sealed, emoji, savedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is StoredReactionPlainRow &&
          other.messageId == this.messageId &&
          other.userId == this.userId &&
          other.sealed == this.sealed &&
          other.emoji == this.emoji &&
          other.savedAt == this.savedAt);
}

class ReactionPlainsCompanion extends UpdateCompanion<StoredReactionPlainRow> {
  final Value<String> messageId;
  final Value<String> userId;
  final Value<String> sealed;
  final Value<String> emoji;
  final Value<int> savedAt;
  final Value<int> rowid;
  const ReactionPlainsCompanion({
    this.messageId = const Value.absent(),
    this.userId = const Value.absent(),
    this.sealed = const Value.absent(),
    this.emoji = const Value.absent(),
    this.savedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReactionPlainsCompanion.insert({
    required String messageId,
    required String userId,
    required String sealed,
    required String emoji,
    required int savedAt,
    this.rowid = const Value.absent(),
  }) : messageId = Value(messageId),
       userId = Value(userId),
       sealed = Value(sealed),
       emoji = Value(emoji),
       savedAt = Value(savedAt);
  static Insertable<StoredReactionPlainRow> custom({
    Expression<String>? messageId,
    Expression<String>? userId,
    Expression<String>? sealed,
    Expression<String>? emoji,
    Expression<int>? savedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (messageId != null) 'message_id': messageId,
      if (userId != null) 'user_id': userId,
      if (sealed != null) 'sealed': sealed,
      if (emoji != null) 'emoji': emoji,
      if (savedAt != null) 'saved_at': savedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReactionPlainsCompanion copyWith({
    Value<String>? messageId,
    Value<String>? userId,
    Value<String>? sealed,
    Value<String>? emoji,
    Value<int>? savedAt,
    Value<int>? rowid,
  }) {
    return ReactionPlainsCompanion(
      messageId: messageId ?? this.messageId,
      userId: userId ?? this.userId,
      sealed: sealed ?? this.sealed,
      emoji: emoji ?? this.emoji,
      savedAt: savedAt ?? this.savedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (userId.present) {
      map['user_id'] = Variable<String>(userId.value);
    }
    if (sealed.present) {
      map['sealed'] = Variable<String>(sealed.value);
    }
    if (emoji.present) {
      map['emoji'] = Variable<String>(emoji.value);
    }
    if (savedAt.present) {
      map['saved_at'] = Variable<int>(savedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReactionPlainsCompanion(')
          ..write('messageId: $messageId, ')
          ..write('userId: $userId, ')
          ..write('sealed: $sealed, ')
          ..write('emoji: $emoji, ')
          ..write('savedAt: $savedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$StoreDatabase extends GeneratedDatabase {
  _$StoreDatabase(QueryExecutor e) : super(e);
  $StoreDatabaseManager get managers => $StoreDatabaseManager(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $SyncStatesTable syncStates = $SyncStatesTable(this);
  late final $MetaTable meta = $MetaTable(this);
  late final $ReadMarksTable readMarks = $ReadMarksTable(this);
  late final $OlmSessionsTable olmSessions = $OlmSessionsTable(this);
  late final $SendQueueRowsTable sendQueueRows = $SendQueueRowsTable(this);
  late final $ReactionPlainsTable reactionPlains = $ReactionPlainsTable(this);
  late final Index messagesConversationCreated = Index(
    'messages_conversation_created',
    'CREATE INDEX messages_conversation_created ON messages (conversation_id, created_at)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    messages,
    conversations,
    syncStates,
    meta,
    readMarks,
    olmSessions,
    sendQueueRows,
    reactionPlains,
    messagesConversationCreated,
  ];
}

typedef $$MessagesTableCreateCompanionBuilder = MessagesCompanion Function({
  required String id,
  required String conversationId,
  required String senderId,
  required int createdAt,
  required String body,
  required String bodyFolded,
  Value<int?> editedAt,
  Value<String?> deleted,
  Value<String?> deletedBy,
  Value<String?> replyTo,
  Value<bool> forwarded,
  Value<bool> poll,
  Value<bool> contact,
  Value<String?> photoGroup,
  Value<String?> extra,
  Value<int> rowid,
});
typedef $$MessagesTableUpdateCompanionBuilder = MessagesCompanion Function({
  Value<String> id,
  Value<String> conversationId,
  Value<String> senderId,
  Value<int> createdAt,
  Value<String> body,
  Value<String> bodyFolded,
  Value<int?> editedAt,
  Value<String?> deleted,
  Value<String?> deletedBy,
  Value<String?> replyTo,
  Value<bool> forwarded,
  Value<bool> poll,
  Value<bool> contact,
  Value<String?> photoGroup,
  Value<String?> extra,
  Value<int> rowid,
});

class $$MessagesTableFilterComposer
    extends Composer<_$StoreDatabase, $MessagesTable> {
  $$MessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bodyFolded => $composableBuilder(
    column: $table.bodyFolded,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get editedAt => $composableBuilder(
    column: $table.editedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get deletedBy => $composableBuilder(
    column: $table.deletedBy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get replyTo => $composableBuilder(
    column: $table.replyTo,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get forwarded => $composableBuilder(
    column: $table.forwarded,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get poll => $composableBuilder(
    column: $table.poll,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get contact => $composableBuilder(
    column: $table.contact,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get photoGroup => $composableBuilder(
    column: $table.photoGroup,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get extra => $composableBuilder(
    column: $table.extra,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MessagesTableOrderingComposer
    extends Composer<_$StoreDatabase, $MessagesTable> {
  $$MessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get senderId => $composableBuilder(
    column: $table.senderId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get body => $composableBuilder(
    column: $table.body,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bodyFolded => $composableBuilder(
    column: $table.bodyFolded,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get editedAt => $composableBuilder(
    column: $table.editedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deleted => $composableBuilder(
    column: $table.deleted,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get deletedBy => $composableBuilder(
    column: $table.deletedBy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get replyTo => $composableBuilder(
    column: $table.replyTo,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get forwarded => $composableBuilder(
    column: $table.forwarded,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get poll => $composableBuilder(
    column: $table.poll,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get contact => $composableBuilder(
    column: $table.contact,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get photoGroup => $composableBuilder(
    column: $table.photoGroup,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get extra => $composableBuilder(
    column: $table.extra,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MessagesTableAnnotationComposer
    extends Composer<_$StoreDatabase, $MessagesTable> {
  $$MessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get senderId =>
      $composableBuilder(column: $table.senderId, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get bodyFolded => $composableBuilder(
    column: $table.bodyFolded,
    builder: (column) => column,
  );

  GeneratedColumn<int> get editedAt =>
      $composableBuilder(column: $table.editedAt, builder: (column) => column);

  GeneratedColumn<String> get deleted =>
      $composableBuilder(column: $table.deleted, builder: (column) => column);

  GeneratedColumn<String> get deletedBy =>
      $composableBuilder(column: $table.deletedBy, builder: (column) => column);

  GeneratedColumn<String> get replyTo =>
      $composableBuilder(column: $table.replyTo, builder: (column) => column);

  GeneratedColumn<bool> get forwarded =>
      $composableBuilder(column: $table.forwarded, builder: (column) => column);

  GeneratedColumn<bool> get poll =>
      $composableBuilder(column: $table.poll, builder: (column) => column);

  GeneratedColumn<bool> get contact =>
      $composableBuilder(column: $table.contact, builder: (column) => column);

  GeneratedColumn<String> get photoGroup => $composableBuilder(
    column: $table.photoGroup,
    builder: (column) => column,
  );

  GeneratedColumn<String> get extra =>
      $composableBuilder(column: $table.extra, builder: (column) => column);
}

class $$MessagesTableTableManager
    extends
        RootTableManager<
          _$StoreDatabase,
          $MessagesTable,
          StoredMessageRow,
          $$MessagesTableFilterComposer,
          $$MessagesTableOrderingComposer,
          $$MessagesTableAnnotationComposer,
          $$MessagesTableCreateCompanionBuilder,
          $$MessagesTableUpdateCompanionBuilder,
          (
            StoredMessageRow,
            BaseReferences<_$StoreDatabase, $MessagesTable, StoredMessageRow>,
          ),
          StoredMessageRow,
          PrefetchHooks Function()
        > {
  $$MessagesTableTableManager(_$StoreDatabase db, $MessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> conversationId = const Value.absent(),
                Value<String> senderId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<String> body = const Value.absent(),
                Value<String> bodyFolded = const Value.absent(),
                Value<int?> editedAt = const Value.absent(),
                Value<String?> deleted = const Value.absent(),
                Value<String?> deletedBy = const Value.absent(),
                Value<String?> replyTo = const Value.absent(),
                Value<bool> forwarded = const Value.absent(),
                Value<bool> poll = const Value.absent(),
                Value<bool> contact = const Value.absent(),
                Value<String?> photoGroup = const Value.absent(),
                Value<String?> extra = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesCompanion(
                id: id,
                conversationId: conversationId,
                senderId: senderId,
                createdAt: createdAt,
                body: body,
                bodyFolded: bodyFolded,
                editedAt: editedAt,
                deleted: deleted,
                deletedBy: deletedBy,
                replyTo: replyTo,
                forwarded: forwarded,
                poll: poll,
                contact: contact,
                photoGroup: photoGroup,
                extra: extra,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String conversationId,
                required String senderId,
                required int createdAt,
                required String body,
                required String bodyFolded,
                Value<int?> editedAt = const Value.absent(),
                Value<String?> deleted = const Value.absent(),
                Value<String?> deletedBy = const Value.absent(),
                Value<String?> replyTo = const Value.absent(),
                Value<bool> forwarded = const Value.absent(),
                Value<bool> poll = const Value.absent(),
                Value<bool> contact = const Value.absent(),
                Value<String?> photoGroup = const Value.absent(),
                Value<String?> extra = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesCompanion.insert(
                id: id,
                conversationId: conversationId,
                senderId: senderId,
                createdAt: createdAt,
                body: body,
                bodyFolded: bodyFolded,
                editedAt: editedAt,
                deleted: deleted,
                deletedBy: deletedBy,
                replyTo: replyTo,
                forwarded: forwarded,
                poll: poll,
                contact: contact,
                photoGroup: photoGroup,
                extra: extra,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MessagesTable, StoredMessageRow>(table),
                  BaseReferences<
                    _$StoreDatabase,
                    $MessagesTable,
                    StoredMessageRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$StoreDatabase,
      $MessagesTable,
      StoredMessageRow,
      $$MessagesTableFilterComposer,
      $$MessagesTableOrderingComposer,
      $$MessagesTableAnnotationComposer,
      $$MessagesTableCreateCompanionBuilder,
      $$MessagesTableUpdateCompanionBuilder,
      (
        StoredMessageRow,
        BaseReferences<_$StoreDatabase, $MessagesTable, StoredMessageRow>,
      ),
      StoredMessageRow,
      PrefetchHooks Function()
    >;
typedef $$ConversationsTableCreateCompanionBuilder =
    ConversationsCompanion Function({
      required String id,
      required String json,
      required int sortAt,
      Value<int> rowid,
    });
typedef $$ConversationsTableUpdateCompanionBuilder =
    ConversationsCompanion Function({
      Value<String> id,
      Value<String> json,
      Value<int> sortAt,
      Value<int> rowid,
    });

class $$ConversationsTableFilterComposer
    extends Composer<_$StoreDatabase, $ConversationsTable> {
  $$ConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get json => $composableBuilder(
    column: $table.json,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortAt => $composableBuilder(
    column: $table.sortAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ConversationsTableOrderingComposer
    extends Composer<_$StoreDatabase, $ConversationsTable> {
  $$ConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get json => $composableBuilder(
    column: $table.json,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortAt => $composableBuilder(
    column: $table.sortAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConversationsTableAnnotationComposer
    extends Composer<_$StoreDatabase, $ConversationsTable> {
  $$ConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get json =>
      $composableBuilder(column: $table.json, builder: (column) => column);

  GeneratedColumn<int> get sortAt =>
      $composableBuilder(column: $table.sortAt, builder: (column) => column);
}

class $$ConversationsTableTableManager
    extends
        RootTableManager<
          _$StoreDatabase,
          $ConversationsTable,
          StoredConversationRow,
          $$ConversationsTableFilterComposer,
          $$ConversationsTableOrderingComposer,
          $$ConversationsTableAnnotationComposer,
          $$ConversationsTableCreateCompanionBuilder,
          $$ConversationsTableUpdateCompanionBuilder,
          (
            StoredConversationRow,
            BaseReferences<
              _$StoreDatabase,
              $ConversationsTable,
              StoredConversationRow
            >,
          ),
          StoredConversationRow,
          PrefetchHooks Function()
        > {
  $$ConversationsTableTableManager(
    _$StoreDatabase db,
    $ConversationsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConversationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> json = const Value.absent(),
                Value<int> sortAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion(
                id: id,
                json: json,
                sortAt: sortAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String json,
                required int sortAt,
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion.insert(
                id: id,
                json: json,
                sortAt: sortAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ConversationsTable, StoredConversationRow>(
                    table,
                  ),
                  BaseReferences<
                    _$StoreDatabase,
                    $ConversationsTable,
                    StoredConversationRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ConversationsTableProcessedTableManager =
    ProcessedTableManager<
      _$StoreDatabase,
      $ConversationsTable,
      StoredConversationRow,
      $$ConversationsTableFilterComposer,
      $$ConversationsTableOrderingComposer,
      $$ConversationsTableAnnotationComposer,
      $$ConversationsTableCreateCompanionBuilder,
      $$ConversationsTableUpdateCompanionBuilder,
      (
        StoredConversationRow,
        BaseReferences<
          _$StoreDatabase,
          $ConversationsTable,
          StoredConversationRow
        >,
      ),
      StoredConversationRow,
      PrefetchHooks Function()
    >;
typedef $$SyncStatesTableCreateCompanionBuilder = SyncStatesCompanion Function({
  required String conversationId,
  Value<int?> newestAt,
  Value<int?> contiguousFrom,
  Value<bool> complete,
  Value<int> rowid,
});
typedef $$SyncStatesTableUpdateCompanionBuilder = SyncStatesCompanion Function({
  Value<String> conversationId,
  Value<int?> newestAt,
  Value<int?> contiguousFrom,
  Value<bool> complete,
  Value<int> rowid,
});

class $$SyncStatesTableFilterComposer
    extends Composer<_$StoreDatabase, $SyncStatesTable> {
  $$SyncStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get newestAt => $composableBuilder(
    column: $table.newestAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get contiguousFrom => $composableBuilder(
    column: $table.contiguousFrom,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get complete => $composableBuilder(
    column: $table.complete,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SyncStatesTableOrderingComposer
    extends Composer<_$StoreDatabase, $SyncStatesTable> {
  $$SyncStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get newestAt => $composableBuilder(
    column: $table.newestAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get contiguousFrom => $composableBuilder(
    column: $table.contiguousFrom,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get complete => $composableBuilder(
    column: $table.complete,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncStatesTableAnnotationComposer
    extends Composer<_$StoreDatabase, $SyncStatesTable> {
  $$SyncStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get newestAt =>
      $composableBuilder(column: $table.newestAt, builder: (column) => column);

  GeneratedColumn<int> get contiguousFrom => $composableBuilder(
    column: $table.contiguousFrom,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get complete =>
      $composableBuilder(column: $table.complete, builder: (column) => column);
}

class $$SyncStatesTableTableManager
    extends
        RootTableManager<
          _$StoreDatabase,
          $SyncStatesTable,
          StoredSyncRow,
          $$SyncStatesTableFilterComposer,
          $$SyncStatesTableOrderingComposer,
          $$SyncStatesTableAnnotationComposer,
          $$SyncStatesTableCreateCompanionBuilder,
          $$SyncStatesTableUpdateCompanionBuilder,
          (
            StoredSyncRow,
            BaseReferences<_$StoreDatabase, $SyncStatesTable, StoredSyncRow>,
          ),
          StoredSyncRow,
          PrefetchHooks Function()
        > {
  $$SyncStatesTableTableManager(_$StoreDatabase db, $SyncStatesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncStatesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<int?> newestAt = const Value.absent(),
                Value<int?> contiguousFrom = const Value.absent(),
                Value<bool> complete = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStatesCompanion(
                conversationId: conversationId,
                newestAt: newestAt,
                contiguousFrom: contiguousFrom,
                complete: complete,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                Value<int?> newestAt = const Value.absent(),
                Value<int?> contiguousFrom = const Value.absent(),
                Value<bool> complete = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncStatesCompanion.insert(
                conversationId: conversationId,
                newestAt: newestAt,
                contiguousFrom: contiguousFrom,
                complete: complete,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SyncStatesTable, StoredSyncRow>(table),
                  BaseReferences<
                    _$StoreDatabase,
                    $SyncStatesTable,
                    StoredSyncRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SyncStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$StoreDatabase,
      $SyncStatesTable,
      StoredSyncRow,
      $$SyncStatesTableFilterComposer,
      $$SyncStatesTableOrderingComposer,
      $$SyncStatesTableAnnotationComposer,
      $$SyncStatesTableCreateCompanionBuilder,
      $$SyncStatesTableUpdateCompanionBuilder,
      (
        StoredSyncRow,
        BaseReferences<_$StoreDatabase, $SyncStatesTable, StoredSyncRow>,
      ),
      StoredSyncRow,
      PrefetchHooks Function()
    >;
typedef $$MetaTableCreateCompanionBuilder = MetaCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$MetaTableUpdateCompanionBuilder = MetaCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$MetaTableFilterComposer extends Composer<_$StoreDatabase, $MetaTable> {
  $$MetaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MetaTableOrderingComposer
    extends Composer<_$StoreDatabase, $MetaTable> {
  $$MetaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MetaTableAnnotationComposer
    extends Composer<_$StoreDatabase, $MetaTable> {
  $$MetaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$MetaTableTableManager
    extends
        RootTableManager<
          _$StoreDatabase,
          $MetaTable,
          StoredMetaRow,
          $$MetaTableFilterComposer,
          $$MetaTableOrderingComposer,
          $$MetaTableAnnotationComposer,
          $$MetaTableCreateCompanionBuilder,
          $$MetaTableUpdateCompanionBuilder,
          (
            StoredMetaRow,
            BaseReferences<_$StoreDatabase, $MetaTable, StoredMetaRow>,
          ),
          StoredMetaRow,
          PrefetchHooks Function()
        > {
  $$MetaTableTableManager(_$StoreDatabase db, $MetaTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MetaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MetaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MetaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => MetaCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) => MetaCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MetaTable, StoredMetaRow>(table),
                  BaseReferences<_$StoreDatabase, $MetaTable, StoredMetaRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MetaTableProcessedTableManager =
    ProcessedTableManager<
      _$StoreDatabase,
      $MetaTable,
      StoredMetaRow,
      $$MetaTableFilterComposer,
      $$MetaTableOrderingComposer,
      $$MetaTableAnnotationComposer,
      $$MetaTableCreateCompanionBuilder,
      $$MetaTableUpdateCompanionBuilder,
      (
        StoredMetaRow,
        BaseReferences<_$StoreDatabase, $MetaTable, StoredMetaRow>,
      ),
      StoredMetaRow,
      PrefetchHooks Function()
    >;
typedef $$ReadMarksTableCreateCompanionBuilder = ReadMarksCompanion Function({
  required String conversationId,
  required String userId,
  required bool shares,
  Value<int?> readAt,
  Value<int?> deliveredAt,
  Value<int> rowid,
});
typedef $$ReadMarksTableUpdateCompanionBuilder = ReadMarksCompanion Function({
  Value<String> conversationId,
  Value<String> userId,
  Value<bool> shares,
  Value<int?> readAt,
  Value<int?> deliveredAt,
  Value<int> rowid,
});

class $$ReadMarksTableFilterComposer
    extends Composer<_$StoreDatabase, $ReadMarksTable> {
  $$ReadMarksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get shares => $composableBuilder(
    column: $table.shares,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get readAt => $composableBuilder(
    column: $table.readAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get deliveredAt => $composableBuilder(
    column: $table.deliveredAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReadMarksTableOrderingComposer
    extends Composer<_$StoreDatabase, $ReadMarksTable> {
  $$ReadMarksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get shares => $composableBuilder(
    column: $table.shares,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get readAt => $composableBuilder(
    column: $table.readAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get deliveredAt => $composableBuilder(
    column: $table.deliveredAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReadMarksTableAnnotationComposer
    extends Composer<_$StoreDatabase, $ReadMarksTable> {
  $$ReadMarksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get conversationId => $composableBuilder(
    column: $table.conversationId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<bool> get shares =>
      $composableBuilder(column: $table.shares, builder: (column) => column);

  GeneratedColumn<int> get readAt =>
      $composableBuilder(column: $table.readAt, builder: (column) => column);

  GeneratedColumn<int> get deliveredAt => $composableBuilder(
    column: $table.deliveredAt,
    builder: (column) => column,
  );
}

class $$ReadMarksTableTableManager
    extends
        RootTableManager<
          _$StoreDatabase,
          $ReadMarksTable,
          StoredReadMarkRow,
          $$ReadMarksTableFilterComposer,
          $$ReadMarksTableOrderingComposer,
          $$ReadMarksTableAnnotationComposer,
          $$ReadMarksTableCreateCompanionBuilder,
          $$ReadMarksTableUpdateCompanionBuilder,
          (
            StoredReadMarkRow,
            BaseReferences<_$StoreDatabase, $ReadMarksTable, StoredReadMarkRow>,
          ),
          StoredReadMarkRow,
          PrefetchHooks Function()
        > {
  $$ReadMarksTableTableManager(_$StoreDatabase db, $ReadMarksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReadMarksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReadMarksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReadMarksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> conversationId = const Value.absent(),
                Value<String> userId = const Value.absent(),
                Value<bool> shares = const Value.absent(),
                Value<int?> readAt = const Value.absent(),
                Value<int?> deliveredAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReadMarksCompanion(
                conversationId: conversationId,
                userId: userId,
                shares: shares,
                readAt: readAt,
                deliveredAt: deliveredAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String conversationId,
                required String userId,
                required bool shares,
                Value<int?> readAt = const Value.absent(),
                Value<int?> deliveredAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReadMarksCompanion.insert(
                conversationId: conversationId,
                userId: userId,
                shares: shares,
                readAt: readAt,
                deliveredAt: deliveredAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReadMarksTable, StoredReadMarkRow>(table),
                  BaseReferences<
                    _$StoreDatabase,
                    $ReadMarksTable,
                    StoredReadMarkRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReadMarksTableProcessedTableManager =
    ProcessedTableManager<
      _$StoreDatabase,
      $ReadMarksTable,
      StoredReadMarkRow,
      $$ReadMarksTableFilterComposer,
      $$ReadMarksTableOrderingComposer,
      $$ReadMarksTableAnnotationComposer,
      $$ReadMarksTableCreateCompanionBuilder,
      $$ReadMarksTableUpdateCompanionBuilder,
      (
        StoredReadMarkRow,
        BaseReferences<_$StoreDatabase, $ReadMarksTable, StoredReadMarkRow>,
      ),
      StoredReadMarkRow,
      PrefetchHooks Function()
    >;
typedef $$OlmSessionsTableCreateCompanionBuilder =
    OlmSessionsCompanion Function({
      required String sessionId,
      required String peerUserId,
      required String peerIdentityKey,
      required String pickle,
      required int lastUsedAt,
      Value<int> rowid,
    });
typedef $$OlmSessionsTableUpdateCompanionBuilder =
    OlmSessionsCompanion Function({
      Value<String> sessionId,
      Value<String> peerUserId,
      Value<String> peerIdentityKey,
      Value<String> pickle,
      Value<int> lastUsedAt,
      Value<int> rowid,
    });

class $$OlmSessionsTableFilterComposer
    extends Composer<_$StoreDatabase, $OlmSessionsTable> {
  $$OlmSessionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peerUserId => $composableBuilder(
    column: $table.peerUserId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get peerIdentityKey => $composableBuilder(
    column: $table.peerIdentityKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pickle => $composableBuilder(
    column: $table.pickle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$OlmSessionsTableOrderingComposer
    extends Composer<_$StoreDatabase, $OlmSessionsTable> {
  $$OlmSessionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peerUserId => $composableBuilder(
    column: $table.peerUserId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get peerIdentityKey => $composableBuilder(
    column: $table.peerIdentityKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pickle => $composableBuilder(
    column: $table.pickle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OlmSessionsTableAnnotationComposer
    extends Composer<_$StoreDatabase, $OlmSessionsTable> {
  $$OlmSessionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sessionId =>
      $composableBuilder(column: $table.sessionId, builder: (column) => column);

  GeneratedColumn<String> get peerUserId => $composableBuilder(
    column: $table.peerUserId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get peerIdentityKey => $composableBuilder(
    column: $table.peerIdentityKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get pickle =>
      $composableBuilder(column: $table.pickle, builder: (column) => column);

  GeneratedColumn<int> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => column,
  );
}

class $$OlmSessionsTableTableManager
    extends
        RootTableManager<
          _$StoreDatabase,
          $OlmSessionsTable,
          StoredOlmSessionRow,
          $$OlmSessionsTableFilterComposer,
          $$OlmSessionsTableOrderingComposer,
          $$OlmSessionsTableAnnotationComposer,
          $$OlmSessionsTableCreateCompanionBuilder,
          $$OlmSessionsTableUpdateCompanionBuilder,
          (
            StoredOlmSessionRow,
            BaseReferences<
              _$StoreDatabase,
              $OlmSessionsTable,
              StoredOlmSessionRow
            >,
          ),
          StoredOlmSessionRow,
          PrefetchHooks Function()
        > {
  $$OlmSessionsTableTableManager(_$StoreDatabase db, $OlmSessionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OlmSessionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OlmSessionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$OlmSessionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> sessionId = const Value.absent(),
                Value<String> peerUserId = const Value.absent(),
                Value<String> peerIdentityKey = const Value.absent(),
                Value<String> pickle = const Value.absent(),
                Value<int> lastUsedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => OlmSessionsCompanion(
                sessionId: sessionId,
                peerUserId: peerUserId,
                peerIdentityKey: peerIdentityKey,
                pickle: pickle,
                lastUsedAt: lastUsedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String sessionId,
                required String peerUserId,
                required String peerIdentityKey,
                required String pickle,
                required int lastUsedAt,
                Value<int> rowid = const Value.absent(),
              }) => OlmSessionsCompanion.insert(
                sessionId: sessionId,
                peerUserId: peerUserId,
                peerIdentityKey: peerIdentityKey,
                pickle: pickle,
                lastUsedAt: lastUsedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$OlmSessionsTable, StoredOlmSessionRow>(table),
                  BaseReferences<
                    _$StoreDatabase,
                    $OlmSessionsTable,
                    StoredOlmSessionRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OlmSessionsTableProcessedTableManager =
    ProcessedTableManager<
      _$StoreDatabase,
      $OlmSessionsTable,
      StoredOlmSessionRow,
      $$OlmSessionsTableFilterComposer,
      $$OlmSessionsTableOrderingComposer,
      $$OlmSessionsTableAnnotationComposer,
      $$OlmSessionsTableCreateCompanionBuilder,
      $$OlmSessionsTableUpdateCompanionBuilder,
      (
        StoredOlmSessionRow,
        BaseReferences<_$StoreDatabase, $OlmSessionsTable, StoredOlmSessionRow>,
      ),
      StoredOlmSessionRow,
      PrefetchHooks Function()
    >;
typedef $$SendQueueRowsTableCreateCompanionBuilder =
    SendQueueRowsCompanion Function({
      required String userId,
      required String id,
      required int position,
      required String record,
      Value<String?> ciphertext,
      Value<int?> olmType,
      Value<int> rowid,
    });
typedef $$SendQueueRowsTableUpdateCompanionBuilder =
    SendQueueRowsCompanion Function({
      Value<String> userId,
      Value<String> id,
      Value<int> position,
      Value<String> record,
      Value<String?> ciphertext,
      Value<int?> olmType,
      Value<int> rowid,
    });

class $$SendQueueRowsTableFilterComposer
    extends Composer<_$StoreDatabase, $SendQueueRowsTable> {
  $$SendQueueRowsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get record => $composableBuilder(
    column: $table.record,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get olmType => $composableBuilder(
    column: $table.olmType,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SendQueueRowsTableOrderingComposer
    extends Composer<_$StoreDatabase, $SendQueueRowsTable> {
  $$SendQueueRowsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get record => $composableBuilder(
    column: $table.record,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get olmType => $composableBuilder(
    column: $table.olmType,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SendQueueRowsTableAnnotationComposer
    extends Composer<_$StoreDatabase, $SendQueueRowsTable> {
  $$SendQueueRowsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get record =>
      $composableBuilder(column: $table.record, builder: (column) => column);

  GeneratedColumn<String> get ciphertext => $composableBuilder(
    column: $table.ciphertext,
    builder: (column) => column,
  );

  GeneratedColumn<int> get olmType =>
      $composableBuilder(column: $table.olmType, builder: (column) => column);
}

class $$SendQueueRowsTableTableManager
    extends
        RootTableManager<
          _$StoreDatabase,
          $SendQueueRowsTable,
          StoredSendQueueRow,
          $$SendQueueRowsTableFilterComposer,
          $$SendQueueRowsTableOrderingComposer,
          $$SendQueueRowsTableAnnotationComposer,
          $$SendQueueRowsTableCreateCompanionBuilder,
          $$SendQueueRowsTableUpdateCompanionBuilder,
          (
            StoredSendQueueRow,
            BaseReferences<
              _$StoreDatabase,
              $SendQueueRowsTable,
              StoredSendQueueRow
            >,
          ),
          StoredSendQueueRow,
          PrefetchHooks Function()
        > {
  $$SendQueueRowsTableTableManager(
    _$StoreDatabase db,
    $SendQueueRowsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SendQueueRowsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SendQueueRowsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SendQueueRowsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> userId = const Value.absent(),
                Value<String> id = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<String> record = const Value.absent(),
                Value<String?> ciphertext = const Value.absent(),
                Value<int?> olmType = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SendQueueRowsCompanion(
                userId: userId,
                id: id,
                position: position,
                record: record,
                ciphertext: ciphertext,
                olmType: olmType,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String userId,
                required String id,
                required int position,
                required String record,
                Value<String?> ciphertext = const Value.absent(),
                Value<int?> olmType = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SendQueueRowsCompanion.insert(
                userId: userId,
                id: id,
                position: position,
                record: record,
                ciphertext: ciphertext,
                olmType: olmType,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SendQueueRowsTable, StoredSendQueueRow>(table),
                  BaseReferences<
                    _$StoreDatabase,
                    $SendQueueRowsTable,
                    StoredSendQueueRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SendQueueRowsTableProcessedTableManager =
    ProcessedTableManager<
      _$StoreDatabase,
      $SendQueueRowsTable,
      StoredSendQueueRow,
      $$SendQueueRowsTableFilterComposer,
      $$SendQueueRowsTableOrderingComposer,
      $$SendQueueRowsTableAnnotationComposer,
      $$SendQueueRowsTableCreateCompanionBuilder,
      $$SendQueueRowsTableUpdateCompanionBuilder,
      (
        StoredSendQueueRow,
        BaseReferences<
          _$StoreDatabase,
          $SendQueueRowsTable,
          StoredSendQueueRow
        >,
      ),
      StoredSendQueueRow,
      PrefetchHooks Function()
    >;
typedef $$ReactionPlainsTableCreateCompanionBuilder =
    ReactionPlainsCompanion Function({
      required String messageId,
      required String userId,
      required String sealed,
      required String emoji,
      required int savedAt,
      Value<int> rowid,
    });
typedef $$ReactionPlainsTableUpdateCompanionBuilder =
    ReactionPlainsCompanion Function({
      Value<String> messageId,
      Value<String> userId,
      Value<String> sealed,
      Value<String> emoji,
      Value<int> savedAt,
      Value<int> rowid,
    });

class $$ReactionPlainsTableFilterComposer
    extends Composer<_$StoreDatabase, $ReactionPlainsTable> {
  $$ReactionPlainsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sealed => $composableBuilder(
    column: $table.sealed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get emoji => $composableBuilder(
    column: $table.emoji,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get savedAt => $composableBuilder(
    column: $table.savedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ReactionPlainsTableOrderingComposer
    extends Composer<_$StoreDatabase, $ReactionPlainsTable> {
  $$ReactionPlainsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get messageId => $composableBuilder(
    column: $table.messageId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userId => $composableBuilder(
    column: $table.userId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sealed => $composableBuilder(
    column: $table.sealed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get emoji => $composableBuilder(
    column: $table.emoji,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get savedAt => $composableBuilder(
    column: $table.savedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ReactionPlainsTableAnnotationComposer
    extends Composer<_$StoreDatabase, $ReactionPlainsTable> {
  $$ReactionPlainsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get messageId =>
      $composableBuilder(column: $table.messageId, builder: (column) => column);

  GeneratedColumn<String> get userId =>
      $composableBuilder(column: $table.userId, builder: (column) => column);

  GeneratedColumn<String> get sealed =>
      $composableBuilder(column: $table.sealed, builder: (column) => column);

  GeneratedColumn<String> get emoji =>
      $composableBuilder(column: $table.emoji, builder: (column) => column);

  GeneratedColumn<int> get savedAt =>
      $composableBuilder(column: $table.savedAt, builder: (column) => column);
}

class $$ReactionPlainsTableTableManager
    extends
        RootTableManager<
          _$StoreDatabase,
          $ReactionPlainsTable,
          StoredReactionPlainRow,
          $$ReactionPlainsTableFilterComposer,
          $$ReactionPlainsTableOrderingComposer,
          $$ReactionPlainsTableAnnotationComposer,
          $$ReactionPlainsTableCreateCompanionBuilder,
          $$ReactionPlainsTableUpdateCompanionBuilder,
          (
            StoredReactionPlainRow,
            BaseReferences<
              _$StoreDatabase,
              $ReactionPlainsTable,
              StoredReactionPlainRow
            >,
          ),
          StoredReactionPlainRow,
          PrefetchHooks Function()
        > {
  $$ReactionPlainsTableTableManager(
    _$StoreDatabase db,
    $ReactionPlainsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReactionPlainsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReactionPlainsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReactionPlainsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> messageId = const Value.absent(),
                Value<String> userId = const Value.absent(),
                Value<String> sealed = const Value.absent(),
                Value<String> emoji = const Value.absent(),
                Value<int> savedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReactionPlainsCompanion(
                messageId: messageId,
                userId: userId,
                sealed: sealed,
                emoji: emoji,
                savedAt: savedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String messageId,
                required String userId,
                required String sealed,
                required String emoji,
                required int savedAt,
                Value<int> rowid = const Value.absent(),
              }) => ReactionPlainsCompanion.insert(
                messageId: messageId,
                userId: userId,
                sealed: sealed,
                emoji: emoji,
                savedAt: savedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReactionPlainsTable, StoredReactionPlainRow>(
                    table,
                  ),
                  BaseReferences<
                    _$StoreDatabase,
                    $ReactionPlainsTable,
                    StoredReactionPlainRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ReactionPlainsTableProcessedTableManager =
    ProcessedTableManager<
      _$StoreDatabase,
      $ReactionPlainsTable,
      StoredReactionPlainRow,
      $$ReactionPlainsTableFilterComposer,
      $$ReactionPlainsTableOrderingComposer,
      $$ReactionPlainsTableAnnotationComposer,
      $$ReactionPlainsTableCreateCompanionBuilder,
      $$ReactionPlainsTableUpdateCompanionBuilder,
      (
        StoredReactionPlainRow,
        BaseReferences<
          _$StoreDatabase,
          $ReactionPlainsTable,
          StoredReactionPlainRow
        >,
      ),
      StoredReactionPlainRow,
      PrefetchHooks Function()
    >;

class $StoreDatabaseManager {
  final _$StoreDatabase _db;
  $StoreDatabaseManager(this._db);
  $$MessagesTableTableManager get messages =>
      $$MessagesTableTableManager(_db, _db.messages);
  $$ConversationsTableTableManager get conversations =>
      $$ConversationsTableTableManager(_db, _db.conversations);
  $$SyncStatesTableTableManager get syncStates =>
      $$SyncStatesTableTableManager(_db, _db.syncStates);
  $$MetaTableTableManager get meta => $$MetaTableTableManager(_db, _db.meta);
  $$ReadMarksTableTableManager get readMarks =>
      $$ReadMarksTableTableManager(_db, _db.readMarks);
  $$OlmSessionsTableTableManager get olmSessions =>
      $$OlmSessionsTableTableManager(_db, _db.olmSessions);
  $$SendQueueRowsTableTableManager get sendQueueRows =>
      $$SendQueueRowsTableTableManager(_db, _db.sendQueueRows);
  $$ReactionPlainsTableTableManager get reactionPlains =>
      $$ReactionPlainsTableTableManager(_db, _db.reactionPlains);
}
