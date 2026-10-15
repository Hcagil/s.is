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

abstract class _$StoreDatabase extends GeneratedDatabase {
  _$StoreDatabase(QueryExecutor e) : super(e);
  $StoreDatabaseManager get managers => $StoreDatabaseManager(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $SyncStatesTable syncStates = $SyncStatesTable(this);
  late final $MetaTable meta = $MetaTable(this);
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
}
