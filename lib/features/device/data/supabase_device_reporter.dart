import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/device_reporter.dart';

/// [DeviceReporter] over the `report_device_info` RPC.
///
/// Sends five facts only: model, OS version, app version, build number,
/// install source. Never the phone's name or any id. Best effort: never
/// throws, one call per app start.
///
/// Model and OS version come from the app's own native channel
/// `sis/device_facts`.
final class SupabaseDeviceReporter implements DeviceReporter {
  SupabaseDeviceReporter(this._client);

  final SupabaseClient _client;

  static const _channel = MethodChannel('sis/device_facts');

  @override
  Future<void> report() async {
    try {
      final pkg = await PackageInfo.fromPlatform();
      final build = int.tryParse(pkg.buildNumber);
      if (build == null) return;

      final facts = await _channel.invokeMapMethod<String, String>('facts');
      if (facts == null) return;
      final model = facts['model'] ?? '';
      final os = facts['os'] ?? '';

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
