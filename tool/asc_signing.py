#!/usr/bin/env python3
"""Signing assets from App Store Connect for one CI run, and their removal.

  asc_signing.py create CSR.pem BUNDLE_ID PROFILE_NAME OUT_DIR
      Creates an Apple Distribution certificate for the CSR and an App Store
      profile for BUNDLE_ID using it. Writes OUT_DIR/cert.cer (DER) and
      OUT_DIR/profile.mobileprovision; prints
      SIGNING_CERTIFICATE_ID=... and SIGNING_PROFILE_ID=... (GITHUB_ENV lines).
  asc_signing.py delete CERTIFICATE_ID PROFILE_ID
      Revokes the certificate and deletes the profile; '-' skips one.

The key is the App Store Connect API key the workflow already holds:
$API_PRIVATE_KEYS_DIR/AuthKey_$KEY_ID.p8 with $KEY_ID and $ISSUER_ID.

Why a certificate per run: the team's name has non-ASCII letters, and the
designated requirement Xcode writes compares the certificate's common name in
a form Apple's own validation does not match ("Code failed to satisfy
specified code requirement(s)"), so the app must be signed by codesign with an
explicit requirement, which needs the private key on the runner. Nothing is
kept: the key is generated in the job and the certificate is revoked when the
job ends. Standard library and openssl only.
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(sig):
    """ECDSA DER SEQUENCE {INTEGER r, INTEGER s} -> r||s, 64 bytes (JWS ES256)."""
    if sig[0] != 0x30:
        sys.exit("openssl: not a DER signature")
    i = 2 if sig[1] < 0x80 else 2 + (sig[1] & 0x7F)
    out = b""
    for _ in range(2):
        if sig[i] != 0x02:
            sys.exit("openssl: not a DER signature")
        n = sig[i + 1]
        out += sig[i + 2 : i + 2 + n].lstrip(b"\0").rjust(32, b"\0")
        i += 2 + n
    return out


def token():
    key_id = os.environ["KEY_ID"]
    key_path = os.path.join(os.environ["API_PRIVATE_KEYS_DIR"], "AuthKey_%s.p8" % key_id)
    now = int(time.time())
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = {"iss": os.environ["ISSUER_ID"], "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}
    payload = b64url(json.dumps(claims).encode())
    signing_input = ("%s.%s" % (header, payload)).encode()
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=signing_input, capture_output=True, check=True,
    ).stdout
    return "%s.%s.%s" % (header, payload, b64url(der_to_raw(der)))


def call(method, path, body=None, ok_missing=False):
    req = urllib.request.Request(
        API + path, method=method,
        data=json.dumps(body).encode() if body is not None else None,
        headers={"Authorization": "Bearer " + token(), "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        if ok_missing and e.code == 404:
            return None
        sys.exit("%s %s: HTTP %s: %s" % (method, path, e.code, e.read().decode(errors="replace")[:2000]))


def create(csr_path, bundle_identifier, profile_name, out_dir):
    with open(csr_path) as f:
        csr = f.read()
    cert = call("POST", "/certificates", {"data": {
        "type": "certificates",
        "attributes": {"csrContent": csr, "certificateType": "DISTRIBUTION"},
    }})["data"]
    with open(os.path.join(out_dir, "cert.cer"), "wb") as f:
        f.write(base64.b64decode(cert["attributes"]["certificateContent"]))
    print("SIGNING_CERTIFICATE_ID=%s" % cert["id"])
    bundles = call("GET", "/bundleIds?filter[identifier]=%s&filter[platform]=IOS" % bundle_identifier)["data"]
    bundles = [b for b in bundles if b["attributes"]["identifier"] == bundle_identifier]
    if not bundles:
        sys.exit("no iOS bundle ID %s in App Store Connect" % bundle_identifier)
    profile = call("POST", "/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": profile_name, "profileType": "IOS_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": bundles[0]["id"]}},
            "certificates": {"data": [{"type": "certificates", "id": cert["id"]}]},
        },
    }})["data"]
    with open(os.path.join(out_dir, "profile.mobileprovision"), "wb") as f:
        f.write(base64.b64decode(profile["attributes"]["profileContent"]))
    print("SIGNING_PROFILE_ID=%s" % profile["id"])


def delete(certificate_id, profile_id):
    if profile_id != "-":
        call("DELETE", "/profiles/%s" % profile_id, ok_missing=True)
    if certificate_id != "-":
        call("DELETE", "/certificates/%s" % certificate_id, ok_missing=True)


def main(argv):
    if argv[1:2] == ["create"] and len(argv) == 6:
        create(*argv[2:])
    elif argv[1:2] == ["delete"] and len(argv) == 4:
        delete(*argv[2:])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
