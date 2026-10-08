import 'package:flutter/foundation.dart';

/// Whether the chat's video picker is SIS's own grid of the phone's videos
/// (true) or the phone's own picker (false), per platform. A plain constant,
/// not a remote flag. Android is on the phone's picker until the owner says
/// "go"; turning it on is this one line plus the READ_MEDIA_VIDEO permission
/// in AndroidManifest.xml (docs/DECISIONS.md, 2026-10-08).
///
/// iPhone: the grid.
const bool videoGridOnIos = true;

/// Android: the phone's own picker (see [videoGridOnIos]).
const bool videoGridOnAndroid = false;

/// [videoGridOnIos] / [videoGridOnAndroid] for the running platform.
bool get inAppVideoGrid => switch (defaultTargetPlatform) {
  TargetPlatform.iOS => videoGridOnIos,
  TargetPlatform.android => videoGridOnAndroid,
  _ => false,
};
