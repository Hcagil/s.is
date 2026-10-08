import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';

import '../domain/auto_download_settings.dart';

/// Uses [connectivity_plus] to detect the current network kind.
///
/// The platform channel 'sis/network' is answered by MainActivity.kt
/// (ConnectivityManager NOT_ROAMING capability) because connectivity_plus
/// cannot tell roaming.
final class ConnectivityNetworkProbe implements NetworkProbe {
  ConnectivityNetworkProbe({
    Connectivity? connectivity,
    MethodChannel channel = const MethodChannel('sis/network'),
  })
  // ignore: prefer_initializing_formals
  : _connectivity = connectivity ?? Connectivity(), _channel = channel;

  final Connectivity _connectivity;
  final MethodChannel _channel;

  @override
  Future<NetworkKind?> current() async {
    try {
      final results = await _connectivity.checkConnectivity();
      if (results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet)) {
        return NetworkKind.wifi;
      }
      if (results.isEmpty ||
          results.every((r) => r == ConnectivityResult.none)) {
        return null;
      }
      if (await _isRoaming()) {
        return NetworkKind.roaming;
      }
      return NetworkKind.mobile;
    } catch (_) {
      return null;
    }
  }

  /// Returns true when the phone is on a roaming network.
  Future<bool> _isRoaming() async {
    try {
      return await _channel.invokeMethod<bool>('isRoaming') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
