import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/autodownload/domain/auto_download_settings.dart';

void main() {
  const Set<MediaKind> allKindsSet = {
    MediaKind.photos,
    MediaKind.audio,
    MediaKind.videos,
    MediaKind.documents,
  };
  const Set<MediaKind> emptySet = {};
  const Set<MediaKind> photosSet = {MediaKind.photos};

  group('AutoDownloadSettings', () {
    group('Defaults', () {
      const defaults = AutoDownloadSettings();

      test('kindsFor returns expected sets', () {
        expect(defaults.kindsFor(NetworkKind.mobile), equals(photosSet));
        expect(defaults.kindsFor(NetworkKind.wifi), equals(allKindsSet));
        expect(defaults.kindsFor(NetworkKind.roaming), equals(emptySet));
      });

      test('allows returns expected booleans', () {
        expect(defaults.allows(NetworkKind.mobile, MediaKind.photos), isTrue);
        expect(
          defaults.allows(NetworkKind.mobile, MediaKind.documents),
          isFalse,
        );
        expect(defaults.allows(NetworkKind.wifi, MediaKind.documents), isTrue);
        expect(defaults.allows(NetworkKind.roaming, MediaKind.photos), isFalse);
      });

      test('preset is null for custom mix', () {
        expect(defaults.preset, isNull);
      });
    });

    group('Presets', () {
      test('forPreset returns correct preset and rules', () {
        for (final preset in AutoDownloadPreset.values) {
          final settings = AutoDownloadSettings.forPreset(preset);
          expect(settings.preset, equals(preset));

          switch (preset) {
            case AutoDownloadPreset.enable:
              expect(
                settings.kindsFor(NetworkKind.mobile),
                equals(allKindsSet),
              );
              expect(settings.kindsFor(NetworkKind.wifi), equals(allKindsSet));
              expect(
                settings.kindsFor(NetworkKind.roaming),
                equals(allKindsSet),
              );
            case AutoDownloadPreset.wifiOnly:
              expect(settings.kindsFor(NetworkKind.mobile), equals(emptySet));
              expect(settings.kindsFor(NetworkKind.wifi), equals(allKindsSet));
              expect(settings.kindsFor(NetworkKind.roaming), equals(emptySet));
            case AutoDownloadPreset.disabled:
              expect(settings.kindsFor(NetworkKind.mobile), equals(emptySet));
              expect(settings.kindsFor(NetworkKind.wifi), equals(emptySet));
              expect(settings.kindsFor(NetworkKind.roaming), equals(emptySet));
          }
        }
      });

      test('allows matches preset semantics', () {
        final enable = AutoDownloadSettings.forPreset(
          AutoDownloadPreset.enable,
        );
        final wifiOnly = AutoDownloadSettings.forPreset(
          AutoDownloadPreset.wifiOnly,
        );
        final disabled = AutoDownloadSettings.forPreset(
          AutoDownloadPreset.disabled,
        );

        expect(enable.allows(NetworkKind.mobile, MediaKind.photos), isTrue);
        expect(enable.allows(NetworkKind.mobile, MediaKind.documents), isTrue);
        expect(wifiOnly.allows(NetworkKind.mobile, MediaKind.photos), isFalse);
        expect(wifiOnly.allows(NetworkKind.wifi, MediaKind.documents), isTrue);
        expect(disabled.allows(NetworkKind.wifi, MediaKind.photos), isFalse);
      });
    });

    group('Preset null when one kind differs', () {
      test('enable preset with roaming photos', () {
        final settings = AutoDownloadSettings.forPreset(
          AutoDownloadPreset.enable,
        ).withKinds(NetworkKind.roaming, {MediaKind.photos});
        expect(settings.preset, isNull);
      });

      test('disabled preset with mobile documents', () {
        final settings = AutoDownloadSettings.forPreset(
          AutoDownloadPreset.disabled,
        ).withKinds(NetworkKind.mobile, {MediaKind.documents});
        expect(settings.preset, isNull);
      });

      test('wifiOnly preset with wifi missing one kind', () {
        final settings =
            AutoDownloadSettings.forPreset(AutoDownloadPreset.wifiOnly)
                .withKinds(NetworkKind.wifi, {
                  MediaKind.photos,
                  MediaKind.audio,
                  MediaKind.videos,
                });
        expect(settings.preset, isNull);
      });
    });

    group('withKinds turning custom mix into preset', () {
      test('defaults -> wifiOnly via two withKinds calls', () {
        final settings = AutoDownloadSettings()
            .withKinds(NetworkKind.mobile, emptySet)
            .withKinds(NetworkKind.wifi, allKindsSet);
        expect(settings.preset, equals(AutoDownloadPreset.wifiOnly));
      });
    });

    group('withKinds immutability', () {
      test('original defaults unchanged after withKinds', () {
        const defaults = AutoDownloadSettings();
        final modified = defaults.withKinds(NetworkKind.mobile, emptySet);
        expect(modified, isNot(same(defaults)));
        expect(defaults.kindsFor(NetworkKind.mobile), equals(photosSet));
        expect(modified.kindsFor(NetworkKind.mobile), equals(emptySet));
      });

      test('other networks unchanged after withKinds', () {
        const defaults = AutoDownloadSettings();
        final modified = defaults.withKinds(NetworkKind.mobile, emptySet);
        expect(modified.kindsFor(NetworkKind.wifi), equals(allKindsSet));
        expect(modified.kindsFor(NetworkKind.roaming), equals(emptySet));
      });
    });

    group('Equality and hashCode', () {
      test('defaults equal to manually constructed same rules', () {
        const defaults = AutoDownloadSettings();
        final manual = AutoDownloadSettings(
          rules: {
            NetworkKind.mobile: photosSet,
            NetworkKind.wifi: allKindsSet,
            NetworkKind.roaming: emptySet,
          },
        );
        expect(manual, equals(defaults));
        expect(manual.hashCode, equals(defaults.hashCode));
      });

      test('kind set order does not affect equality', () {
        final a = const AutoDownloadSettings().withKinds(NetworkKind.roaming, {
          MediaKind.documents,
          MediaKind.photos,
        });
        final b = const AutoDownloadSettings().withKinds(NetworkKind.roaming, {
          MediaKind.photos,
          MediaKind.documents,
        });
        expect(a, equals(b));
        expect(a.hashCode, b.hashCode);
        expect(a, isNot(equals(const AutoDownloadSettings())));
      });

      test('different presets are not equal', () {
        final enable = AutoDownloadSettings.forPreset(
          AutoDownloadPreset.enable,
        );
        final disabled = AutoDownloadSettings.forPreset(
          AutoDownloadPreset.disabled,
        );
        expect(enable, isNot(equals(disabled)));
      });
    });

    group('withKinds defensive copy', () {
      test('modifying input set after withKinds does not affect result', () {
        final mutableSet = {MediaKind.photos};
        final settings = AutoDownloadSettings().withKinds(
          NetworkKind.mobile,
          mutableSet,
        );
        mutableSet.add(MediaKind.documents);
        expect(
          settings.kindsFor(NetworkKind.mobile),
          equals({MediaKind.photos}),
        );
      });
    });
  });
}
