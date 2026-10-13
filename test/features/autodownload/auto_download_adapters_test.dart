import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sis/features/autodownload/data/connectivity_network_probe.dart';
import 'package:sis/features/autodownload/data/shared_prefs_auto_download_store.dart';
import 'package:sis/features/autodownload/domain/auto_download_settings.dart';

/// Fake Connectivity implementation used in tests.
class _Conn implements Connectivity {
  _Conn(this.results, {this.fail = false});
  final List<ConnectivityResult> results;
  final bool fail;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    await Future<void>.delayed(const Duration(milliseconds: 1));
    if (fail) throw PlatformException(code: 'boom');
    return results;
  }

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      Stream.value(results);
}

/// Helper to mock the roaming channel.
void roaming(Object? answer, {bool error = false}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('sis/network'), (
        call,
      ) async {
        calls.add(call.method);
        if (error) throw PlatformException(code: 'x');
        return answer;
      });
}

final calls = <String>[];

void main() {
  group('ConnectivityNetworkProbe', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      calls.clear();
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('sis/network'), null);
    });

    test('wifi only returns NetworkKind.wifi', () async {
      roaming(false);
      final probe = ConnectivityNetworkProbe(
        connectivity: _Conn([ConnectivityResult.wifi]),
      );
      expect(await probe.current(), equals(NetworkKind.wifi));
    });

    test('mobile not roaming returns NetworkKind.mobile', () async {
      roaming(false);
      final probe = ConnectivityNetworkProbe(
        connectivity: _Conn([ConnectivityResult.mobile]),
      );
      expect(await probe.current(), equals(NetworkKind.mobile));
    });

    test('mobile roaming returns NetworkKind.roaming', () async {
      roaming(true);
      final probe = ConnectivityNetworkProbe(
        connectivity: _Conn([ConnectivityResult.mobile]),
      );
      expect(await probe.current(), equals(NetworkKind.roaming));
    });

    test('none or empty list returns null', () async {
      roaming(false);
      final probe1 = ConnectivityNetworkProbe(
        connectivity: _Conn([ConnectivityResult.none]),
      );
      final probe2 = ConnectivityNetworkProbe(connectivity: _Conn([]));
      expect(await probe1.current(), isNull);
      expect(await probe2.current(), isNull);
    });

    test('wifi wins over mobile when roaming', () async {
      roaming(true);
      final probe = ConnectivityNetworkProbe(
        connectivity: _Conn([
          ConnectivityResult.wifi,
          ConnectivityResult.mobile,
        ]),
      );
      expect(await probe.current(), equals(NetworkKind.wifi));
    });

    test('checkConnectivity throws does not propagate', () async {
      roaming(false);
      final probe = ConnectivityNetworkProbe(
        connectivity: _Conn([], fail: true),
      );
      await expectLater(probe.current(), completes);
    });

    test(
      'roaming channel throws does not propagate and result is not wifi',
      () async {
        roaming(null, error: true);
        final probe = ConnectivityNetworkProbe(
          connectivity: _Conn([ConnectivityResult.mobile]),
        );
        final result = await probe.current();
        expect(result, isNot(NetworkKind.wifi));
      },
    );

    test('unknown network kinds are not offline', () async {
      roaming(false);
      final unknownKinds = [
        ConnectivityResult.other,
        ConnectivityResult.vpn,
        ConnectivityResult.bluetooth,
        ConnectivityResult.satellite,
      ];
      for (final kind in unknownKinds) {
        final probe = ConnectivityNetworkProbe(connectivity: _Conn([kind]));
        final result = await probe.current();
        expect(result, isNotNull);
      }
    });
  });

  group('SharedPrefsAutoDownloadStore', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
    });

    test('nothing saved returns default settings', () async {
      const store = SharedPrefsAutoDownloadStore();
      final settings = await store.load();
      expect(settings, equals(const AutoDownloadSettings()));
    });

    test('save and load round‑trip for presets and custom', () async {
      const store = SharedPrefsAutoDownloadStore();
      final presets = [
        AutoDownloadSettings.forPreset(AutoDownloadPreset.enable),
        AutoDownloadSettings.forPreset(AutoDownloadPreset.disabled),
        AutoDownloadSettings.forPreset(AutoDownloadPreset.wifiOnly),
        const AutoDownloadSettings().withKinds(NetworkKind.roaming, {
          MediaKind.photos,
          MediaKind.documents,
        }),
      ];
      for (final preset in presets) {
        await store.save(preset);
        final loaded = await const SharedPrefsAutoDownloadStore().load();
        expect(loaded, equals(preset));
      }
    });

    test('saving disabled keeps disabled state', () async {
      const store = SharedPrefsAutoDownloadStore();
      final disabled = AutoDownloadSettings.forPreset(
        AutoDownloadPreset.disabled,
      );
      await store.save(disabled);
      final loaded = await const SharedPrefsAutoDownloadStore().load();
      expect(loaded, equals(disabled));
    });

    test('unreadable data results in default settings', () async {
      const store = SharedPrefsAutoDownloadStore();
      final settings = AutoDownloadSettings.forPreset(
        AutoDownloadPreset.enable,
      );
      await store.save(settings);
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final badData = <String, Object>{};
      for (final key in keys) {
        badData[key] = 7;
      }
      SharedPreferences.setMockInitialValues(badData);
      final loaded = await const SharedPrefsAutoDownloadStore().load();
      expect(loaded, equals(const AutoDownloadSettings()));
    });

    test('unknown kind names stored are ignored', () async {
      const store = SharedPrefsAutoDownloadStore();
      final settings = AutoDownloadSettings.forPreset(
        AutoDownloadPreset.enable,
      );
      await store.save(settings);
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final badData = <String, Object>{};
      for (final key in keys) {
        badData[key] = <String>['nonsense'];
      }
      SharedPreferences.setMockInitialValues(badData);
      await expectLater(const SharedPrefsAutoDownloadStore().load(), completes);
    });
  });
}
