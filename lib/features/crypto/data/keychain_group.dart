import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('sis/keychain');

/// The iOS keychain access group that holds the store key and the Olm pickle key (TEAMID.com.esd.sis.crypto), shared with the notification extension only. Null elsewhere, and on a build without signing (then the default group is used). The app has already moved the keys into it before Flutter starts (ios/Runner/SisKeychain.swift).
Future<String?> cryptoKeychainGroup() async {
  if (!Platform.isIOS) return null;
  try {
    return await _channel.invokeMethod<String>('cryptoGroup');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}
