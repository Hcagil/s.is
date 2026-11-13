import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// What this phone keeps for the admin panels: its own key pair, the computer key it confirmed (pinned), and the sequence counters.
final class AdminKeys {
  const AdminKeys({
    required this.secret,
    required this.public,
    this.pinned,
    this.published = false,
    this.pinnedEpoch = 0,
    this.upEpoch = 0,
    this.upSeq = 0,
    this.downEpoch = 0,
    this.downSeq = 0,
  });

  /// 32 bytes.
  final List<int> secret;

  /// 32 bytes.
  final List<int> public;

  /// The computer public key confirmed with the 60-digit code.
  final List<int>? pinned;

  /// This public key was sent to the server.
  final bool published;

  /// The server epoch when the code was confirmed.
  final int pinnedEpoch;

  /// Epoch of the last sent up sequence.
  final int upEpoch;

  /// Last sent up sequence.
  final int upSeq;

  /// Epoch of the last applied down sequence.
  final int downEpoch;

  /// Last applied down sequence.
  final int downSeq;

  AdminKeys copyWith({
    List<int>? pinned,
    bool? published,
    int? pinnedEpoch,
    int? upEpoch,
    int? upSeq,
    int? downEpoch,
    int? downSeq,
  }) {
    return AdminKeys(
      secret: secret,
      public: public,
      pinned: pinned ?? this.pinned,
      published: published ?? this.published,
      pinnedEpoch: pinnedEpoch ?? this.pinnedEpoch,
      upEpoch: upEpoch ?? this.upEpoch,
      upSeq: upSeq ?? this.upSeq,
      downEpoch: downEpoch ?? this.downEpoch,
      downSeq: downSeq ?? this.downSeq,
    );
  }

  AdminKeys withoutPin() {
    return AdminKeys(
      secret: secret,
      public: public,
      pinned: null,
      published: published,
      pinnedEpoch: 0,
      upEpoch: upEpoch,
      upSeq: upSeq,
      downEpoch: downEpoch,
      downSeq: downSeq,
    );
  }
}

/// The admin panels keys in the platform's secure storage (Keystore / Keychain), in their own entry.
final class AdminKeyStore {
  AdminKeyStore([FlutterSecureStorage? storage])
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // A read error must never delete the key: it throws, and callers retry later.
            aOptions: AndroidOptions(resetOnError: false),
            // This device only: the key must never travel in an iCloud or Finder
            // backup together with the database file.
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock_this_device,
            ),
          );

  static const _name = 'sis.admin.panels';
  final FlutterSecureStorage _storage;

  Future<AdminKeys?> load() async {
    final raw = await _storage.read(key: _name);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final v = json['v'];
      if (v != 1) return null;

      final skBase64 = json['sk'] as String?;
      final pkBase64 = json['pk'] as String?;
      if (skBase64 == null || pkBase64 == null) return null;

      final secret = base64Decode(skBase64);
      final public = base64Decode(pkBase64);
      if (secret.length != 32 || public.length != 32) return null;

      List<int>? pinned;
      final pinBase64 = json['pin'] as String?;
      if (pinBase64 != null) {
        pinned = base64Decode(pinBase64);
        if (pinned.length != 32) return null;
      }

      final published = json['pub'] == true;
      final pinnedEpoch = json['pe'] is int ? json['pe'] as int : 0;
      final upEpoch = json['ue'] is int ? json['ue'] as int : 0;
      final upSeq = json['us'] is int ? json['us'] as int : 0;
      final downEpoch = json['de'] is int ? json['de'] as int : 0;
      final downSeq = json['ds'] is int ? json['ds'] as int : 0;

      return AdminKeys(
        secret: secret,
        public: public,
        pinned: pinned,
        published: published,
        pinnedEpoch: pinnedEpoch,
        upEpoch: upEpoch,
        upSeq: upSeq,
        downEpoch: downEpoch,
        downSeq: downSeq,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> save(AdminKeys keys) async {
    final map = <String, dynamic>{
      'v': 1,
      'sk': base64Encode(keys.secret),
      'pk': base64Encode(keys.public),
      'pin': keys.pinned != null ? base64Encode(keys.pinned!) : null,
      'pub': keys.published,
      'pe': keys.pinnedEpoch,
      'ue': keys.upEpoch,
      'us': keys.upSeq,
      'de': keys.downEpoch,
      'ds': keys.downSeq,
    };
    await _storage.write(key: _name, value: jsonEncode(map));
  }

  Future<void> delete() async {
    await _storage.delete(key: _name);
  }
}
