import 'dart:io' show Platform;

/// The Android application id a restricted Google Maps key is checked against.
const String mapsAndroidPackage = 'com.esd.sis';

/// The iOS bundle id a restricted Google Maps key is checked against.
const String mapsIosBundleId = 'com.esd.sis';

/// SHA-1 fingerprint (hex, no colons) of the certificate that signs the Android app on Google Play. EMPTY UNTIL THE OWNER SUPPLIES IT: while it is empty the X-Android-Cert header is left out, and a key restricted to Android apps refuses the call.
const String mapsAndroidCertSha1 = '';

/// The headers that tell Google which app is calling, for the REST calls (Places, Geocoding, Static Maps) made with a key restricted to this app. Empty on other platforms.
Map<String, String> mapsRequestHeaders() => {
  if (Platform.isAndroid) 'X-Android-Package': mapsAndroidPackage,
  if (Platform.isAndroid && mapsAndroidCertSha1.isNotEmpty)
    'X-Android-Cert': mapsAndroidCertSha1,
  if (Platform.isIOS) 'X-Ios-Bundle-Identifier': mapsIosBundleId,
};
