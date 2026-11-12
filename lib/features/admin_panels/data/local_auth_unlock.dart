import 'package:local_auth/local_auth.dart';

import '../domain/admin_panels_repository.dart';

/// The phone unlock (fingerprint, face or PIN) through local_auth.
final class LocalAuthUnlock implements AdminUnlock {
  LocalAuthUnlock([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<AdminUnlockResult> authenticate(String reason) async {
    // No lock set on the phone: the panels must stay closed.
    if (!await _auth.isDeviceSupported()) return AdminUnlockResult.noLock;
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: false,
      );
      return ok ? AdminUnlockResult.ok : AdminUnlockResult.cancelled;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noBiometricHardware => AdminUnlockResult.noLock,
        _ => AdminUnlockResult.cancelled,
      };
    }
  }
}
