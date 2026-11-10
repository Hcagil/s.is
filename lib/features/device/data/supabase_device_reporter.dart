import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/device_reporter.dart';

/// [DeviceReporter] over the `report_device_info` RPC.
///
/// Sends five facts only: model, OS version, app version, build number,
/// install source. Never the phone's name or any id. Best effort: never
/// throws, one call per app start.
final class SupabaseDeviceReporter implements DeviceReporter {
  SupabaseDeviceReporter(this._client);

  final SupabaseClient _client;

  @override
  Future<void> report() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      final build = int.tryParse(pkg.buildNumber);
      if (build == null) return;

      final String model;
      final String os;

      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await plugin.androidInfo;
        model = a.model;
        os = a.version.release;
      } else if (Platform.isIOS) {
        final i = await plugin.iosInfo;
        model = i.utsname.machine;
        os = i.systemVersion;
      } else {
        return;
      }

      await _client.rpc(
        'report_device_info',
        params: {
          'p_model': model,
          'p_os_version': os,
          'p_app_version': pkg.version,
          'p_build': build,
          'p_installer': pkg.installerStore ?? '',
        },
      );
    } catch (_) {}
  }
}
