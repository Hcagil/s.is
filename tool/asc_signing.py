#!/usr/bin/env python3
"""App Store Connect for CI: the long-lived signing identity, and TestFlight distribution.

  asc_signing.py create CSR.pem BUNDLE_ID PROFILE_NAME OUT_DIR
      Creates an Apple Distribution certificate for the CSR and an App Store
      profile for BUNDLE_ID using it. Writes OUT_DIR/cert.cer (DER) and
      OUT_DIR/profile.mobileprovision; prints
      SIGNING_CERTIFICATE_ID=... and SIGNING_PROFILE_ID=... (GITHUB_ENV lines).
  asc_signing.py delete CERTIFICATE_ID PROFILE_ID
      Revokes the certificate, then deletes the profile (kept if the revoke
      failed); '-' skips one; exits non-zero on a failure (404 is fine).
      For rotation; no pipeline step calls it.
  asc_signing.py distribute BUNDLE_ID BUILD_NUMBER GROUPS NOTE
      After an upload: waits until the build is VALID (polls every
      $ASC_POLL_SECONDS, default 30, for at most $ASC_POLL_LIMIT_SECONDS,
      default 3600), sets its en-US What to Test from NOTE (empty: "Bug fixes
      and improvements."), adds it to every external beta
      group named in GROUPS (comma-separated, case-insensitive) and, if there
      is one, submits it for beta app review. Internal groups are skipped:
      they get builds by themselves ("Enable automatic distribution"). Safe
      to re-run.
  asc_signing.py fetch PROFILE_NAME OUT_DIR
      The signing identity of every run: finds the ACTIVE profile named
      PROFILE_NAME (the newest, if several) and the distribution certificate it
      uses; writes OUT_DIR/cert.cer (DER) and OUT_DIR/profile.mobileprovision;
      prints ids only (SIGNING_CERTIFICATE_ID=..., SIGNING_PROFILE_ID=...).
      Fails if there is none or either has expired; prints a ::warning:: when
      either expires within 30 days.
  asc_signing.py cleanup [MIN_AGE_HOURS]
      One-time sweep of the old per-run material: profiles named
      "sis ci <run>-<attempt>" (nothing else is touched; not the long-lived
      one) created at least MIN_AGE_HOURS ago (default 6), each with its
      certificates (certificates first). Tries everything, then exits 1 if
      anything failed.

The key is the App Store Connect API key the workflow already holds:
$API_PRIVATE_KEYS_DIR/AuthKey_$KEY_ID.p8 with $KEY_ID and $ISSUER_ID.

Why one long-lived certificate: Apple validates the signature of a build not
only while processing it but again in TestFlight beta review (up to about 48
hours later), and a certificate revoked by then fails the build (ITMS-90721,
ITMS-90035); Apple allows only three distribution certificates, so per-run
ones cannot be kept until each review ends. One certificate, created once by
the iOS signing bootstrap workflow, with its private key kept as the repository
secret IOS_DISTRIBUTION_KEY, is fetched by every run and revoked only on
rotation. A certificate is needed at all because the team's name has non-ASCII
letters and the designated requirement Xcode writes compares the certificate's
common name in a form Apple's own validation does not match ("Code failed to
satisfy specified code requirement(s)"), so the app must be signed by codesign
with an explicit requirement, which needs the private key on the runner.
Standard library and openssl only.
"""
import base64
import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
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


def call(method, path, body=None, ok_missing=False, tolerate=(), hint=""):
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
        if e.code in tolerate:
            return None
        sys.exit("%s %s: HTTP %s: %s%s" % (method, path, e.code, e.read().decode(errors="replace")[:2000], " " + hint if hint else ""))
    except OSError as e:
        sys.exit("%s %s: %s" % (method, path, type(e).__name__))


def create(csr_path, bundle_identifier, profile_name, out_dir):
    with open(csr_path) as f:
        csr = f.read()
    cert = call("POST", "/certificates", {"data": {
        "type": "certificates",
        "attributes": {"csrContent": csr, "certificateType": "DISTRIBUTION"},
    }})["data"]
    print("SIGNING_CERTIFICATE_ID=%s" % cert["id"], flush=True)
    with open(os.path.join(out_dir, "cert.cer"), "wb") as f:
        f.write(base64.b64decode(cert["attributes"]["certificateContent"]))
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
    print("SIGNING_PROFILE_ID=%s" % profile["id"], flush=True)
    with open(os.path.join(out_dir, "profile.mobileprovision"), "wb") as f:
        f.write(base64.b64decode(profile["attributes"]["profileContent"]))


def delete(certificate_id, profile_id):
    # Certificate first: the profile is the only way to find the certificate
    # again, so it is kept when the certificate delete failed.
    failed = False
    for path, ident in ("/certificates/", certificate_id), ("/profiles/", profile_id):
        if ident == "-" or (failed and path == "/profiles/"):
            continue
        try:
            call("DELETE", path + ident, ok_missing=True)
        except SystemExit as e:
            print(e.code, file=sys.stderr, flush=True)
            failed = True
    if failed:
        sys.exit(1)


def parse_date(s):
    """An App Store Connect date ('Z', '+0000' or '+00:00' offset) as an aware datetime."""
    s = s.replace("Z", "+00:00")
    if s[-5] in "+-" and s[-3] != ":":
        s = s[:-2] + ":" + s[-2:]
    return datetime.datetime.fromisoformat(s)


def build_state(app_id, build_number):
    builds = call("GET", "/builds?filter[app]=%s&filter[version]=%s&limit=1" % (app_id, build_number))["data"]
    # Right after the upload the build is not listed yet.
    return builds, builds[0]["attributes"]["processingState"] if builds else "NOT LISTED YET"


def find_app(bundle_identifier):
    apps = call("GET", "/apps?filter[bundleId]=%s" % bundle_identifier)["data"]
    apps = [a for a in apps if a["attributes"]["bundleId"] == bundle_identifier]
    if not apps:
        sys.exit("no app %s in App Store Connect" % bundle_identifier)
    return apps[0]["id"]


def cleanup(min_age_hours=6.0):
    """One-time sweep of old per-run material: 'sis ci <run>-<attempt>' profiles and their certificates."""
    now = datetime.datetime.now(datetime.timezone.utc)
    failed = False
    for p in call("GET", "/profiles?limit=200")["data"]:
        if not re.fullmatch(r"sis ci [0-9]+-[0-9]+", p["attributes"]["name"]):
            continue
        age = (now - parse_date(p["attributes"]["createdDate"])).total_seconds() / 3600
        if age < min_age_hours:
            continue
        try:
            stuck = False
            for c in call("GET", "/profiles/%s/certificates" % p["id"])["data"]:
                try:
                    delete(c["id"], "-")
                except SystemExit:
                    stuck = failed = True
            if not stuck:  # a leftover certificate keeps its profile, the only way to find it again
                delete("-", p["id"])
                print("removed leftover profile %s (age %.1f h)" % (p["id"], age), flush=True)
        except SystemExit:
            failed = True
    if failed:
        sys.exit(1)


def fetch(profile_name, out_dir):
    """Writes the long-lived certificate and profile to out_dir; warns before they expire."""
    found = call("GET", "/profiles?filter[name]=%s&limit=200" % urllib.parse.quote(profile_name))["data"]
    # The name filter matches partially: keep the exact name.
    found = [p for p in found if p["attributes"]["name"] == profile_name and p["attributes"]["profileState"] == "ACTIVE"]
    if not found:
        sys.exit("no active profile named %s in App Store Connect; run the iOS signing bootstrap workflow" % profile_name)
    profile = max(found, key=lambda p: parse_date(p["attributes"]["createdDate"]))
    certs = call("GET", "/profiles/%s/certificates" % profile["id"])["data"]
    certs = [c for c in certs if c["attributes"].get("certificateType", "DISTRIBUTION") == "DISTRIBUTION"]
    if not certs:
        sys.exit("the profile %s uses no distribution certificate" % profile["id"])
    cert = certs[0]
    now = datetime.datetime.now(datetime.timezone.utc)
    for what, item in ("certificate", cert), ("profile", profile):
        if "expirationDate" not in item["attributes"]:
            continue
        days = (parse_date(item["attributes"]["expirationDate"]) - now).total_seconds() / 86400
        if days <= 0:
            sys.exit("the signing %s expired; rotate it (docs/DELIVERY.md)" % what)
        if days < 30:
            print("::warning::The iOS signing %s expires in %d days; rotate it (docs/DELIVERY.md)" % (what, days), flush=True)
    with open(os.path.join(out_dir, "cert.cer"), "wb") as f:
        f.write(base64.b64decode(cert["attributes"]["certificateContent"]))
    with open(os.path.join(out_dir, "profile.mobileprovision"), "wb") as f:
        f.write(base64.b64decode(profile["attributes"]["profileContent"]))
    print("SIGNING_CERTIFICATE_ID=%s" % cert["id"], flush=True)
    print("SIGNING_PROFILE_ID=%s" % profile["id"], flush=True)


def distribute(bundle_identifier, build_number, groups, note):
    """Waits for the uploaded build, sets its What to Test and hands it to the groups."""
    app_id = find_app(bundle_identifier)

    interval = float(os.environ.get("ASC_POLL_SECONDS", "30"))
    deadline = time.monotonic() + float(os.environ.get("ASC_POLL_LIMIT_SECONDS", "3600"))
    while True:
        builds, state = build_state(app_id, build_number)
        print("build %s: %s" % (build_number, state), flush=True)
        if state == "VALID":
            break
        if state in ("FAILED", "INVALID"):
            sys.exit("App Store Connect could not process build %s (%s)" % (build_number, state))
        if time.monotonic() + interval > deadline:
            sys.exit("build %s still %s at the polling limit; re-run this job later" % (build_number, state))
        time.sleep(interval)
    build_id = builds[0]["id"]

    text = (note.strip() or "Bug fixes and improvements.")[:4000]
    locs = call("GET", "/builds/%s/betaBuildLocalizations" % build_id)["data"]
    en_us = [l for l in locs if l["attributes"]["locale"] == "en-US"]
    if en_us:
        call("PATCH", "/betaBuildLocalizations/%s" % en_us[0]["id"], {"data": {
            "type": "betaBuildLocalizations", "id": en_us[0]["id"], "attributes": {"whatsNew": text},
        }})
    else:
        call("POST", "/betaBuildLocalizations", {"data": {
            "type": "betaBuildLocalizations",
            "attributes": {"locale": "en-US", "whatsNew": text},
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
        }})

    # Names match case-insensitively. Internal groups are never POSTed to: App
    # Store Connect rejects it (422) and adds builds itself when "Enable automatic
    # distribution" is on for the group.
    wanted = {g.strip().lower() for g in groups}
    every = call("GET", "/apps/%s/betaGroups?limit=200" % app_id)["data"]
    matched = [g for g in every if g["attributes"]["name"].strip().lower() in wanted]
    if not matched:
        sys.exit("no TestFlight group named %s; the app has: %s" % (
            ", ".join(groups), ", ".join(g["attributes"]["name"] for g in every) or "none"))
    for g in matched:
        if g["attributes"]["isInternalGroup"]:
            print("internal group %s receives builds automatically" % g["attributes"]["name"], flush=True)
            continue
        print("adding to external group %s" % g["attributes"]["name"], flush=True)
        # 409: already in the group (or the group takes every build): not an error.
        call("POST", "/betaGroups/%s/relationships/builds" % g["id"],
             {"data": [{"type": "builds", "id": build_id}]}, tolerate=(409,))

    if any(not g["attributes"]["isInternalGroup"] for g in matched):
        existing = call("GET", "/builds/%s/betaAppReviewSubmission" % build_id, ok_missing=True)
        if existing and existing.get("data"):
            print("already submitted for beta review", flush=True)
            return
        call("POST", "/betaAppReviewSubmissions", {"data": {
            "type": "betaAppReviewSubmissions",
            "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
        }}, hint="If this says Test Information is missing, the owner must fill it in once: "
                 "App Store Connect, TestFlight, Test Information (beta app description, feedback "
                 "email, review contact). This tool does not invent them.")
        print("submitted for beta review", flush=True)


def main(argv):
    if argv[1:2] == ["create"] and len(argv) == 6:
        create(*argv[2:])
    elif argv[1:2] == ["delete"] and len(argv) == 4:
        delete(*argv[2:])
    elif argv[1:2] == ["distribute"] and len(argv) == 6:
        distribute(argv[2], argv[3], [g.strip() for g in argv[4].split(",") if g.strip()], argv[5])
    elif argv[1:2] == ["fetch"] and len(argv) == 4:
        fetch(*argv[2:])
    elif argv[1:2] == ["cleanup"] and len(argv) in (2, 3):
        cleanup(*[float(a) for a in argv[2:]])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
