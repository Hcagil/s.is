import 'admin_panels_repository.dart';

/// Where the link stands, from four facts.
///
/// [ownKeyOnServer]: this phone has a key pair, it was published, and the server holds exactly that public key.
/// [computerKeyPresent]: the server holds a computer public key.
/// [hasPin]: this phone pinned a computer key earlier (it confirmed a code).
/// [pinMatches]: the pinned key equals the computer key on the server now.
AdminLinkPhase linkPhase({
  required bool ownKeyOnServer,
  required bool computerKeyPresent,
  required bool hasPin,
  required bool pinMatches,
}) {
  if (!ownKeyOnServer) return AdminLinkPhase.unlinked;
  if (!computerKeyPresent) {
    return hasPin ? AdminLinkPhase.changed : AdminLinkPhase.waiting;
  }
  if (hasPin && pinMatches) return AdminLinkPhase.linked;
  if (hasPin) return AdminLinkPhase.changed;
  return AdminLinkPhase.confirm;
}
