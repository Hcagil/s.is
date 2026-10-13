import 'package:flutter_test/flutter_test.dart';
import 'package:sis/features/chat/data/url_launcher_maps_opener.dart';
import 'package:sis/features/chat/domain/geo.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import '../../../support/url_launcher_platform.dart';

// The host runs as "not Android", so these reach the maps-link branch. The
// Android geo: branch is chosen by dart:io Platform.isAndroid, which a host
// test cannot switch; its %28/%29 label encoding is not covered here.
void main() {
  late FakeUrlLauncherPlatform fake;

  setUp(() {
    fake = FakeUrlLauncherPlatform();
    UrlLauncherPlatform.instance = fake;
  });

  test('hands one link with the point and the encoded label', () async {
    final opened = await const UrlLauncherMapsOpener().open(
      const GeoPoint(41.0082, 28.9784),
      'Cafe (Kadikoy)',
    );

    expect(opened, isTrue);
    expect(fake.launches, hasLength(1));
    final url = Uri.parse(fake.launches.single.url);
    expect(fake.launches.single.url, contains('41.008200'));
    expect(fake.launches.single.url, contains('28.978400'));
    expect(url.queryParameters.values, contains('Cafe (Kadikoy)'));
  });

  test('returns false, without throwing, when no app opens it', () async {
    fake.handles = (_) => false;

    final opened = await const UrlLauncherMapsOpener().open(
      const GeoPoint(41.0082, 28.9784),
      'Any place',
    );

    expect(opened, isFalse);
  });
}
