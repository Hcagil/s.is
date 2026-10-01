#!/usr/bin/env python3
"""tool/asc_signing.py against a local fake App Store Connect API.

The tool is run as the workflow runs it (a separate python3 process, argv
and environment only); the one change is its API base URL, pointed at a
stdlib HTTP server on 127.0.0.1 that answers like App Store Connect:
JSON:API bodies, 201 on create, 204 on delete, a 404 / 409 / 500 carrying an
`errors` list, and a bundle-id filter that matches partially (the real
`filter[identifier]` also returns ids that merely contain the string).

  token   ES256 JWT: header alg ES256, kid = KEY_ID, typ JWT; claims iss =
          ISSUER_ID, aud appstoreconnect-v1, exp in the future and at most
          20 minutes away; signature verifies with the key's public half
          (raw r||s, 64 bytes, converted from openssl's DER).
  create  looks the bundle id up, creates a DISTRIBUTION certificate from the
          CSR and an IOS_APP_STORE profile tying the exact bundle id to that
          certificate; writes OUT/cert.cer (DER) and
          OUT/profile.mobileprovision; stdout carries only the lines
          SIGNING_CERTIFICATE_ID / SIGNING_PROFILE_ID. A failure after the
          certificate exists still reports its id and exits non-zero. Only the
          iOS signing bootstrap workflow calls it.
  fetch   PROFILE_NAME OUT_DIR: the long-lived identity every run signs with.
          Lists profiles (filter[name], limit 200; the filter matches
          partially), takes the ACTIVE one named exactly PROFILE_NAME, the
          newest by createdDate; then its first DISTRIBUTION certificate (no
          certificateType attribute counts too). Writes OUT/cert.cer and
          OUT/profile.mobileprovision; stdout: the two id lines and nothing
          else but ::warning:: lines. Expired (<= 0 days) certificate or
          profile: exit 1 "the signing <x> expired; rotate it
          (docs/DELIVERY.md)"; under 30 days: "::warning::The iOS signing <x>
          expires in N days; rotate it (docs/DELIVERY.md)". No such profile,
          no distribution certificate, an API error: non-zero. Only GETs.
  delete  CERT_ID PROFILE_ID: the certificate first, then the profile; `-`
          skips one; a failed certificate delete keeps the profile and exits
          1; a failed profile delete exits 1; 404 is fine.
  cleanup [MIN_AGE_HOURS=6]: one-time sweep of the old per-run material:
          only profiles named exactly "sis ci <digits>-<digits>" at least that
          old; per profile, each certificate first (each tried on its own),
          the profile only when all its certificates went; never "sis ci
          distribution", another profile or certificate; 404 is fine; any
          failure exits 1 after trying everything; prints ids and ages, never
          names or content. Ages are checked under TZ=JST-9.
  release is gone: it is a usage error.
  never   prints the private key or the bearer token.

Needs python3 and openssl only.
"""
import base64
import datetime
import http.server
import select
import socket
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
TOOL = os.path.join(ROOT, "tool", "asc_signing.py")
KEY_ID, ISSUER = "K3YID", "69a6de7e-issuer-uuid"
BUNDLES = {"BID-WIDGET": "com.esd.sis.widget", "BID-APP": "com.esd.sis", "BID-OTHER": "com.other.app"}
PROFILE_BYTES = b"0\x82\x01\x00fake-cms-" + os.urandom(32)
CONTENT_MARK = base64.b64encode(b"KEYMATERIAL-" + os.urandom(24)).decode()


def sh(*cmd, data=None):
    return subprocess.run(cmd, input=data, capture_output=True, check=True).stdout


def b64url_decode(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def der_int(b):
    b = b.lstrip(b"\0") or b"\0"
    if b[0] & 0x80:
        b = b"\0" + b
    return b"\x02" + bytes([len(b)]) + b


def raw_to_der(raw):
    body = der_int(raw[:32]) + der_int(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


def attrs(base, over):
    """base updated from over; a None value drops the attribute."""
    d = dict(base, **(over or {}))
    return {k: v for k, v in d.items() if v is not None}


class Fake(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, status, body=None):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(status)
        if data:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def error(self, status):
        self.reply(status, {"errors": [{"status": str(status), "code": "ERR%d" % status,
                                        "title": "fake error", "detail": "fake error %d" % status}]})

    def handle_any(self):
        st = self.server.state
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        url = urllib.parse.urlsplit(self.path)
        st["requests"].append({"method": self.command, "path": url.path,
                               "query": urllib.parse.parse_qs(url.query),
                               "headers": {k.lower(): v for k, v in self.headers.items()},
                               "body": json.loads(raw) if raw else None})
        st["requests"][-1]["t"] = time.time()
        key = (self.command, url.path)
        forced = st["fail"].get(key) or st["fail"].get((self.command, url.path.rsplit("/", 1)[0]))
        if forced == "drop":  # the connection dies mid-request: no status line at all
            self.close_connection = True
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        if forced == "hang":  # an API that is slow to answer
            time.sleep(8)
            forced = None
        if forced:
            return self.error(forced)
        q = urllib.parse.parse_qs(url.query)
        if key == ("GET", "/v1/apps"):
            # Like filter[identifier], filter[bundleId] is treated as matching partially.
            f = q.get("filter[bundleId]", [""])[0]
            data = [{"type": "apps", "id": i, "attributes": {"bundleId": v}} for i, v in st["apps"] if f in v]
            return self.reply(200, {"data": data})
        if key == ("GET", "/v1/builds"):
            states = st["builds"]
            state = states.pop(0) if len(states) > 1 else states[0]
            if (q.get("filter[app]") != ["APP-1"] or q.get("filter[version]") != [st["version"]]) or state is None:
                return self.reply(200, {"data": []})
            return self.reply(200, {"data": [{"type": "builds", "id": "BUILD-1", "attributes": {
                "version": st["version"], "processingState": state}}]})
        if key == ("GET", "/v1/builds/BUILD-1/betaBuildLocalizations"):
            return self.reply(200, {"data": [{"type": "betaBuildLocalizations", "id": i, "attributes": {
                "locale": loc, "whatsNew": "old"}} for i, loc in st["locs"]]})
        if self.command == "PATCH" and url.path.startswith("/v1/betaBuildLocalizations/"):
            lid = url.path.rsplit("/", 1)[1]
            if lid not in dict(st["locs"]):
                return self.error(404)
            return self.reply(200, {"data": {"type": "betaBuildLocalizations", "id": lid}})
        if key == ("POST", "/v1/betaBuildLocalizations"):
            return self.reply(201, {"data": {"type": "betaBuildLocalizations", "id": "L-NEW"}})
        if key == ("GET", "/v1/apps/APP-1/betaGroups"):
            return self.reply(200, {"data": [{"type": "betaGroups", "id": i, "attributes": {
                "name": n, "isInternalGroup": internal}} for i, n, internal in st["groups"]]})
        if self.command == "POST" and re.fullmatch(r"/v1/betaGroups/[^/]+/relationships/builds", url.path):
            gid = url.path.split("/")[3]
            if gid not in [g[0] for g in st["groups"]]:
                return self.error(404)
            if dict((g[0], g[2]) for g in st["groups"])[gid]:
                # Apple refuses manual additions to an internal group (seen on a real run).
                return self.reply(422, {"errors": [{"status": "422", "code": "ENTITY_ERROR",
                                                    "detail": "Builds cannot be assigned to this internal group."}]})
            return self.reply(204)
        if key == ("GET", "/v1/builds/BUILD-1/betaAppReviewSubmission"):
            sub = {"type": "betaAppReviewSubmissions", "id": "SUB-1",
                   "attributes": {"betaReviewState": "WAITING_FOR_REVIEW"}} if st["review"] else None
            return self.reply(200, {"data": sub})
        if key == ("POST", "/v1/betaAppReviewSubmissions"):
            return self.reply(201, {"data": {"type": "betaAppReviewSubmissions", "id": "SUB-2"}})
        if key == ("GET", "/v1/bundleIds"):
            f = urllib.parse.parse_qs(url.query).get("filter[identifier]", [""])[0]
            data = [{"type": "bundleIds", "id": i, "attributes": {"identifier": v, "platform": "IOS"}}
                    for i, v in BUNDLES.items() if f in v]
            return self.reply(200, {"data": data, "links": {"self": self.path}, "meta": {"paging": {"total": len(data)}}})
        if key == ("POST", "/v1/certificates"):
            return self.reply(201, {"data": {"type": "certificates", "id": "CERT-1", "attributes": {
                "certificateType": "DISTRIBUTION", "name": "Apple Distribution: Şirket",
                "certificateContent": st.get("cert_b64") or base64.b64encode(st["cert_der"]).decode()}}})
        if key == ("POST", "/v1/profiles"):
            return self.reply(201, {"data": {"type": "profiles", "id": "PROF-1", "attributes": {
                "profileType": "IOS_APP_STORE", "uuid": "0F1E2D3C-UUID",
                "profileContent": st.get("prof_b64") or base64.b64encode(PROFILE_BYTES).decode()}}})
        if key == ("GET", "/v1/profiles"):
            # Every profile of the team, ours and others'; filter[name] (if
            # used) matches partially, like the other filters.
            # filter[name] (if used) matches partially and ignores case.
            f = q.get("filter[name]", [""])[0].lower()
            lim = int(q.get("limit", ["20"])[0])
            data = [{"type": "profiles", "id": i, "attributes": attrs({
                "name": n, "createdDate": c, "profileState": "ACTIVE", "profileType": "IOS_APP_STORE",
                "uuid": "UUID-" + i, "profileContent": CONTENT_MARK}, st["pattrs"].get(i))}
                for i, n, c, _ in st["profiles"] if f in n.lower()]
            return self.reply(200, {"data": data[:lim], "links": {"self": self.path}, "meta": {"paging": {"total": len(data)}}})
        m = re.fullmatch(r"/v1/profiles/([^/]+)/certificates", url.path)
        if self.command == "GET" and m:
            certs = {i: cs for i, _, _, cs in st["profiles"]}
            if m.group(1) not in certs:
                return self.error(404)
            return self.reply(200, {"data": [{"type": "certificates", "id": c, "attributes": attrs({
                "certificateType": "DISTRIBUTION", "name": "Apple Distribution: Şirket",
                "certificateContent": CONTENT_MARK}, st["cattrs"].get(c))} for c in certs[m.group(1)]]})
        if self.command == "DELETE" and url.path.rsplit("/", 1)[0] in ("/v1/certificates", "/v1/profiles"):
            if url.path in st["gone"]:  # deleted already: Apple answers 404
                return self.error(404)
            st["gone"].add(url.path)
            return self.reply(204)
        return self.error(404)

    do_GET = do_POST = do_DELETE = do_PATCH = handle_any


class AscSigningTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.keys = os.path.join(cls.tmp, "keys")
        os.mkdir(cls.keys)
        cls.p8 = os.path.join(cls.keys, "AuthKey_%s.p8" % KEY_ID)
        sh("openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", cls.p8)
        with open(cls.p8) as f:
            cls.key_pem = f.read()
        cls.pub = os.path.join(cls.tmp, "pub.pem")
        sh("openssl", "pkey", "-in", cls.p8, "-pubout", "-out", cls.pub)
        cls.csr = os.path.join(cls.tmp, "csr.pem")
        sh("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", os.path.join(cls.tmp, "k.pem"),
           "-out", cls.csr, "-subj", "/CN=sis test run")
        cls.csr_der = sh("openssl", "req", "-in", cls.csr, "-outform", "der")
        ca = os.path.join(cls.tmp, "ca")
        sh("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", ca + ".key", "-out", ca + ".pem",
           "-subj", "/CN=Test WWDR", "-days", "2")
        cls.cert_der = sh("openssl", "req", "-x509", "-in", cls.csr, "-CA", ca + ".pem", "-CAkey", ca + ".key",
                          "-days", "1", "-outform", "der")
        cls.srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fake)
        threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.api = "http://127.0.0.1:%d/v1" % cls.srv.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def setUp(self):
        self.srv.state = {"requests": [], "fail": {}, "cert_der": self.cert_der,
                          "apps": [("APP-W", "com.esd.sis.widget"), ("APP-1", "com.esd.sis"), ("APP-X", "com.other.app")],
                          "version": "412", "builds": ["VALID"], "locs": [("L-DE", "de-DE"), ("L-EN", "en-US")],
                          "groups": [("G-INT", "bacanaks", True), ("G-EXT", "bacanaks", False), ("G-OTHER", "other", True),
                                     ("G-OLD", "bacanaks-old", False), ("G-FR", "Friends", False)],
                          "review": False, "profiles": [], "gone": set(), "pattrs": {}, "cattrs": {}}

    def prog(self, code):
        return ("import sys; sys.path.insert(0, %r); import asc_signing as a; a.API = sys.argv[1]; " % os.path.dirname(TOOL)) + code

    def env(self, **extra):
        return dict(os.environ, API_PRIVATE_KEYS_DIR=self.keys, KEY_ID=KEY_ID, ISSUER_ID=ISSUER, **extra)

    def tool(self, *args, code="a.main(['asc_signing.py'] + sys.argv[2:])", api=None, **extra):
        """Runs the tool in its own process with only API redirected."""
        p = subprocess.run([sys.executable, "-c", self.prog(code), api or self.api, *args], env=self.env(**extra),
                           capture_output=True, text=True, timeout=60)
        self.assertNotIn("PRIVATE KEY", p.stdout + p.stderr, "the key was printed")
        body = "".join(l for l in self.key_pem.splitlines() if "-----" not in l)
        for chunk in (body[i:i + 16] for i in range(0, len(body) - 16, 16)):
            self.assertNotIn(chunk, p.stdout + p.stderr, "part of the key was printed")
        for r in self.srv.state["requests"]:
            tok = r["headers"].get("authorization", "Bearer ?").split(" ", 1)[1]
            self.assertNotIn(tok, p.stdout + p.stderr, "the bearer token was printed")
        return p

    def reqs(self, method=None):
        return [r for r in self.srv.state["requests"] if method in (None, r["method"])]

    def verify_jwt(self, tok):
        h, c, s = tok.split(".")
        for part in (h, c, s):
            self.assertNotIn("=", part, "JWT parts must be unpadded base64url")
        header, claims, sig = json.loads(b64url_decode(h)), json.loads(b64url_decode(c)), b64url_decode(s)
        self.assertEqual(header.get("alg"), "ES256")
        self.assertEqual(header.get("kid"), KEY_ID)
        self.assertEqual(header.get("typ"), "JWT")
        self.assertEqual(claims.get("iss"), ISSUER)
        self.assertEqual(claims.get("aud"), "appstoreconnect-v1")
        now = time.time()
        self.assertGreater(claims["exp"], now, "token already expired")
        self.assertLessEqual(claims["exp"] - now, 20 * 60 + 5, "exp more than 20 minutes away: Apple refuses it")
        if "iat" in claims:
            self.assertLessEqual(claims["iat"], now + 5)
        self.assertEqual(len(sig), 64, "ES256 signature must be raw r||s (64 bytes), not DER")
        sigf = os.path.join(self.tmp, "sig.der")
        with open(sigf, "wb") as f:
            f.write(raw_to_der(sig))
        v = subprocess.run(["openssl", "dgst", "-sha256", "-verify", self.pub, "-signature", sigf],
                           input=("%s.%s" % (h, c)).encode(), capture_output=True)
        self.assertEqual(v.returncode, 0, "JWT signature does not verify with the key's public half: %s" % v.stdout)

    # ---- token ------------------------------------------------------------------
    def test_jwt_on_every_request(self):
        p = self.tool("create", self.csr, "com.esd.sis", "sis ci 1-1", tempfile.mkdtemp())
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(self.reqs())
        for r in self.reqs():
            auth = r["headers"].get("authorization", "")
            self.assertTrue(auth.startswith("Bearer "), "%s %s without a bearer token" % (r["method"], r["path"]))
            self.verify_jwt(auth[7:])

    def test_many_tokens_verify(self):
        # Many signatures: r and s with the high bit set (DER adds a 0x00) and,
        # now and then, a short r or s (DER drops leading zeros) both occur.
        p = self.tool(code="[print(a.token()) for _ in range(60)]")
        self.assertEqual(p.returncode, 0, p.stderr)
        toks = p.stdout.split()
        self.assertEqual(len(toks), 60)
        for t in toks:
            self.verify_jwt(t)

    def test_der_to_raw(self):
        r_short = bytes(range(1, 32))                 # 31 bytes: must be left-padded
        s_high = b"\x80" + bytes(range(2, 33))        # 32 bytes, high bit: DER carries 0x00 in front
        der = raw_to_der(b"\0" + r_short + s_high)
        self.assertEqual(der[3], 31)
        self.assertEqual(der[3 + 31 + 1 + 1], 33)
        p = self.tool(der.hex(), code="sys.stdout.write(a.der_to_raw(bytes.fromhex(sys.argv[2])).hex())")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout, (b"\0" + r_short + s_high).hex())

    # ---- create -----------------------------------------------------------------
    def test_create(self):
        out = tempfile.mkdtemp()
        p = self.tool("create", self.csr, "com.esd.sis", "sis ci 77-2", out)
        self.assertEqual(p.returncode, 0, p.stderr)
        lines = p.stdout.splitlines()
        self.assertEqual(sorted(lines), ["SIGNING_CERTIFICATE_ID=CERT-1", "SIGNING_PROFILE_ID=PROF-1"],
                         "stdout is appended to GITHUB_ENV: only KEY=VALUE lines")
        with open(os.path.join(out, "cert.cer"), "rb") as f:
            self.assertEqual(f.read(), self.cert_der, "cert.cer is not the DER certificate")
        with open(os.path.join(out, "profile.mobileprovision"), "rb") as f:
            self.assertEqual(f.read(), PROFILE_BYTES)

        gets = [r for r in self.reqs("GET") if r["path"] == "/v1/bundleIds"]
        self.assertTrue(gets, "no bundle id lookup")
        self.assertIn("com.esd.sis", gets[0]["query"].get("filter[identifier]", []))

        certs = [r for r in self.reqs("POST") if r["path"] == "/v1/certificates"]
        self.assertEqual(len(certs), 1, "want exactly one certificate created")
        d = certs[0]["body"]["data"]
        self.assertEqual(d["type"], "certificates")
        self.assertEqual(d["attributes"]["certificateType"], "DISTRIBUTION")
        csr = "".join(l for l in d["attributes"]["csrContent"].splitlines() if "-----" not in l)
        self.assertEqual(base64.b64decode(csr), self.csr_der, "csrContent is not the CSR")
        self.assertIn("application/json", certs[0]["headers"].get("content-type", ""))

        profs = [r for r in self.reqs("POST") if r["path"] == "/v1/profiles"]
        self.assertEqual(len(profs), 1, "want exactly one profile created")
        d = profs[0]["body"]["data"]
        self.assertEqual(d["type"], "profiles")
        self.assertEqual(d["attributes"]["name"], "sis ci 77-2")
        self.assertEqual(d["attributes"]["profileType"], "IOS_APP_STORE")
        self.assertEqual(d["relationships"]["bundleId"]["data"], {"type": "bundleIds", "id": "BID-APP"},
                         "the profile must name the exact bundle id, not a partial filter match")
        self.assertEqual(d["relationships"]["certificates"]["data"], [{"type": "certificates", "id": "CERT-1"}])
        self.assertIn("application/json", profs[0]["headers"].get("content-type", ""))
        self.assertFalse(self.reqs("DELETE"))

    def test_create_unknown_bundle_fails(self):
        p = self.tool("create", self.csr, "com.esd.nothere", "n", tempfile.mkdtemp())
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse([r for r in self.reqs("POST") if r["path"] == "/v1/profiles"])
        self.assert_cert_reported(p)

    def test_certificate_refused(self):
        # 409: the team already has the maximum of distribution certificates.
        self.srv.state["fail"][("POST", "/v1/certificates")] = 409
        out = tempfile.mkdtemp()
        p = self.tool("create", self.csr, "com.esd.sis", "n", out)
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse([r for r in self.reqs("POST") if r["path"] == "/v1/profiles"])
        self.assertNotIn("SIGNING_PROFILE_ID", p.stdout)

    def test_profile_refused_still_reports_certificate(self):
        self.srv.state["fail"][("POST", "/v1/profiles")] = 500
        p = self.tool("create", self.csr, "com.esd.sis", "n", tempfile.mkdtemp())
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("SIGNING_CERTIFICATE_ID=CERT-1", p.stdout.splitlines(),
                      "a created certificate must be reported, or the revoke step leaks it")
        self.assertNotIn("SIGNING_PROFILE_ID", p.stdout)

    def assert_cert_reported(self, p):
        made = [r for r in self.reqs("POST") if r["path"] == "/v1/certificates"]
        if made:
            self.assertIn("SIGNING_CERTIFICATE_ID=CERT-1", p.stdout.splitlines(), "a created certificate was not reported")

    def test_bad_usage(self):
        for args in ([], ["create", self.csr, "com.esd.sis", "n"], ["delete", "C"], ["revoke", "C", "P"],
                     ["release", "com.esd.sis", "412", "C", "P"], ["release", "com.esd.sis", "412", "C"],
                     ["distribute", "com.esd.sis", "412", "bacanaks"],
                     ["distribute", "com.esd.sis", "412", "bacanaks", "note", "extra"]):
            self.setUp()
            p = self.tool(*args)
            self.assertNotEqual(p.returncode, 0, "usage %s accepted" % args)
            self.assertFalse(self.reqs(), "usage %s made a request" % args)

    # ---- delete -----------------------------------------------------------------
    def deleted(self):
        """Every resource a DELETE was sent for (a repeat of one counts once)."""
        return sorted({r["path"] for r in self.reqs("DELETE")})

    def test_delete_both(self):
        p = self.tool("delete", "CERT-9", "PROF-9")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.deleted(), ["/v1/certificates/CERT-9", "/v1/profiles/PROF-9"])
        for r in self.reqs("DELETE"):
            self.verify_jwt(r["headers"]["authorization"][7:])
        self.assertEqual([r for r in self.reqs() if r["method"] != "DELETE"], [])

    def test_delete_dash_skips(self):
        for args, want in ((("-", "PROF-9"), ["/v1/profiles/PROF-9"]),
                           (("CERT-9", "-"), ["/v1/certificates/CERT-9"]),
                           (("-", "-"), [])):
            self.setUp()
            p = self.tool("delete", *args)
            self.assertEqual(p.returncode, 0, "%s: %s" % (args, p.stderr))
            self.assertEqual(self.deleted(), want, args)

    def test_delete_404_tolerated(self):
        self.srv.state["fail"].update({("DELETE", "/v1/certificates"): 404, ("DELETE", "/v1/profiles"): 404})
        p = self.tool("delete", "CERT-9", "PROF-9")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.deleted(), ["/v1/certificates/CERT-9", "/v1/profiles/PROF-9"])

    def test_delete_other_errors_fail(self):
        for path, status in (("/v1/certificates", 500), ("/v1/profiles", 500), ("/v1/certificates", 401),
                             ("/v1/profiles", 403), ("/v1/certificates", 409)):
            self.setUp()
            self.srv.state["fail"][("DELETE", path)] = status
            p = self.tool("delete", "CERT-9", "PROF-9")
            self.assertNotEqual(p.returncode, 0, "%d on %s was ignored" % (status, path))

    def test_delete_certificate_before_profile(self):
        p = self.tool("delete", "CERT-9", "PROF-9")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([r["path"] for r in self.reqs("DELETE")], ["/v1/certificates/CERT-9", "/v1/profiles/PROF-9"],
                         "the certificate must be revoked before its profile is deleted")

    def test_delete_failed_certificate_keeps_profile(self):
        for fault in (500, 401, 409, "drop"):
            self.setUp()
            self.srv.state["fail"][("DELETE", "/v1/certificates/CERT-9")] = fault
            p = self.tool("delete", "CERT-9", "PROF-9")
            self.assertEqual(p.returncode, 1, "%s on the certificate: want exit 1, got %d" % (fault, p.returncode))
            self.assertEqual(self.deleted(), ["/v1/certificates/CERT-9"],
                             "%s on the certificate: the profile was deleted anyway" % fault)

    def test_delete_failed_profile_fails(self):
        for fault in (500, 403, "drop"):
            self.setUp()
            self.srv.state["fail"][("DELETE", "/v1/profiles/PROF-9")] = fault
            p = self.tool("delete", "CERT-9", "PROF-9")
            self.assertEqual(p.returncode, 1, "%s on the profile: want exit 1, got %d" % (fault, p.returncode))
            self.assertEqual(self.deleted(), ["/v1/certificates/CERT-9", "/v1/profiles/PROF-9"])

    # ---- create: the ids reach GITHUB_ENV whatever fails after ----------------------
    def test_create_reports_ids_before_writing(self):
        for blocked, want in (("cert.cer", ["SIGNING_CERTIFICATE_ID=CERT-1"]),
                              ("profile.mobileprovision", ["SIGNING_CERTIFICATE_ID=CERT-1", "SIGNING_PROFILE_ID=PROF-1"])):
            self.setUp()
            out = tempfile.mkdtemp()
            os.mkdir(os.path.join(out, blocked))  # the file cannot be written
            p = self.tool("create", self.csr, "com.esd.sis", "n", out)
            self.assertNotEqual(p.returncode, 0, "writing %s over a directory succeeded" % blocked)
            for line in want:
                self.assertIn(line, p.stdout.splitlines(), "%s not reported when %s could not be written" % (line, blocked))

    def test_create_reports_ids_on_broken_content(self):
        for field, want in (("cert_b64", ["SIGNING_CERTIFICATE_ID=CERT-1"]),
                            ("prof_b64", ["SIGNING_CERTIFICATE_ID=CERT-1", "SIGNING_PROFILE_ID=PROF-1"])):
            self.setUp()
            self.srv.state[field] = "abcde"  # not base64 (bad padding)
            p = self.tool("create", self.csr, "com.esd.sis", "n", tempfile.mkdtemp())
            self.assertNotEqual(p.returncode, 0, "broken %s accepted" % field)
            for line in want:
                self.assertIn(line, p.stdout.splitlines(), "%s not reported on broken %s" % (line, field))

    def test_create_flushes_certificate_id(self):
        # The id must be on stdout while the run is still going: a runner that
        # cancels the job kills the process, and unflushed output is lost.
        self.srv.state["fail"][("POST", "/v1/profiles")] = "hang"
        out = tempfile.mkdtemp()
        p = subprocess.Popen([sys.executable, "-c", self.prog("a.main(['asc_signing.py'] + sys.argv[2:])"), self.api,
                              "create", self.csr, "com.esd.sis", "n", out],
                             env=self.env(), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            ready, _, _ = select.select([p.stdout], [], [], 6)
            line = p.stdout.readline().decode() if ready else ""
        finally:
            p.kill()
            p.wait()
            p.stdout.close()
        self.assertEqual(line.strip(), "SIGNING_CERTIFICATE_ID=CERT-1",
                         "the certificate id was not flushed before the profile request")

    # ---- call(): a network failure -------------------------------------------------
    def test_connection_refused_is_reported_briefly(self):
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        p = self.tool("distribute", "com.esd.sis", "412", "bacanaks", "n", api="http://127.0.0.1:%d/v1" % port)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("GET", p.stderr)
        self.assertIn("/apps", p.stderr)
        self.assertIn("URLError", p.stderr)
        self.assertNotIn("Traceback", p.stderr)

    def test_dropped_connection_is_reported_without_body(self):
        self.srv.state["fail"][("PATCH", "/v1/betaBuildLocalizations/L-EN")] = "drop"
        p = self.tool("distribute", "com.esd.sis", "412", "bacanaks", "SECRET-NOTE-BODY", ASC_POLL_SECONDS="0")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("PATCH", p.stderr)
        self.assertIn("/betaBuildLocalizations/L-EN", p.stderr)
        self.assertNotIn("SECRET-NOTE-BODY", p.stderr + p.stdout, "the request body was printed")
        self.assertNotIn("Traceback", p.stderr)

    # ---- distribute ------------------------------------------------------------------
    def dist(self, groups="bacanaks", note="Note", **extra):
        extra.setdefault("ASC_POLL_SECONDS", "0")
        extra.setdefault("ASC_POLL_LIMIT_SECONDS", "30")
        return self.tool("distribute", "com.esd.sis", "412", groups, note, **extra)

    def find(self, method, path):
        return [r for r in self.reqs(method) if r["path"] == path]

    def group_adds(self):
        return sorted(r["path"].split("/")[3] for r in self.reqs("POST") if r["path"].endswith("/relationships/builds"))

    def review_reqs(self):
        return [r for r in self.reqs() if "betaAppReviewSubmission" in r["path"]]

    def whats_new(self):
        writes = [r for r in self.reqs() if r["path"].startswith("/v1/betaBuildLocalizations") and r["method"] in ("PATCH", "POST")]
        self.assertEqual(len(writes), 1, "want one localization write, got %s" % [(r["method"], r["path"]) for r in writes])
        return writes[0]["body"]["data"]["attributes"]["whatsNew"]

    def test_distribute_full_sequence(self):
        self.srv.state["builds"] = [None, "PROCESSING", "VALID"]
        p = self.dist(note='  Line one\nLine "two" şğ  \n')
        self.assertEqual(p.returncode, 0, p.stderr)
        rs = self.reqs()
        self.assertEqual((rs[0]["method"], rs[0]["path"]), ("GET", "/v1/apps"))
        self.assertEqual(rs[0]["query"].get("filter[bundleId]"), ["com.esd.sis"])
        builds = self.find("GET", "/v1/builds")
        self.assertEqual(len(builds), 3, "an empty list or PROCESSING must keep polling until VALID")
        for b in builds:
            self.assertEqual(b["query"].get("filter[app]"), ["APP-1"], "the build was looked up under a partial bundle match")
            self.assertEqual(b["query"].get("filter[version]"), ["412"])
            self.assertEqual(b["query"].get("limit"), ["1"])
        self.assertTrue(self.find("GET", "/v1/builds/BUILD-1/betaBuildLocalizations"))
        patch = self.find("PATCH", "/v1/betaBuildLocalizations/L-EN")
        self.assertEqual(len(patch), 1, "the en-US localization was not updated")
        self.assertEqual(patch[0]["body"]["data"]["type"], "betaBuildLocalizations")
        self.assertEqual(patch[0]["body"]["data"]["id"], "L-EN")
        self.assertEqual(self.whats_new(), 'Line one\nLine "two" şğ')
        self.assertIn("application/json", patch[0]["headers"].get("content-type", ""))
        lg = self.find("GET", "/v1/apps/APP-1/betaGroups")
        self.assertEqual(len(lg), 1)
        self.assertEqual(lg[0]["query"].get("limit"), ["200"])
        self.assertEqual(self.group_adds(), ["G-EXT"], "only the external bacanaks group, nothing else")
        self.assertIn("internal group bacanaks receives builds automatically", p.stdout + p.stderr)
        for r in self.reqs("POST"):
            if r["path"].endswith("/relationships/builds"):
                self.assertEqual(r["body"], {"data": [{"type": "builds", "id": "BUILD-1"}]})
        self.assertEqual(len(self.find("GET", "/v1/builds/BUILD-1/betaAppReviewSubmission")), 1)
        sub = self.find("POST", "/v1/betaAppReviewSubmissions")
        self.assertEqual(len(sub), 1, "an external group needs a beta review submission")
        self.assertEqual(sub[0]["body"]["data"]["type"], "betaAppReviewSubmissions")
        self.assertEqual(sub[0]["body"]["data"]["relationships"]["build"]["data"], {"type": "builds", "id": "BUILD-1"})
        order = [next(i for i, r in enumerate(rs) if pred(r)) for pred in (
            lambda r: r["path"] == "/v1/builds",
            lambda r: r["method"] == "PATCH",
            lambda r: r["path"].endswith("/betaGroups"),
            lambda r: r["path"].endswith("/relationships/builds"),
            lambda r: "betaAppReviewSubmission" in r["path"])]
        self.assertEqual(order, sorted(order), "requests out of the contract order")
        self.assertEqual([r for r in rs if r["method"] == "DELETE"], [])

    def test_distribute_posts_en_us_when_missing(self):
        self.srv.state["locs"] = [("L-DE", "de-DE")]
        p = self.dist(note="Hello")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse(self.reqs("PATCH"), "another locale was overwritten")
        post = self.find("POST", "/v1/betaBuildLocalizations")
        self.assertEqual(len(post), 1)
        d = post[0]["body"]["data"]
        self.assertEqual(d["type"], "betaBuildLocalizations")
        self.assertEqual(d["attributes"]["locale"], "en-US")
        self.assertEqual(d["attributes"]["whatsNew"], "Hello")
        self.assertEqual(d["relationships"]["build"]["data"], {"type": "builds", "id": "BUILD-1"})

    def test_distribute_note_default_and_limit(self):
        for note, want in (("", "Bug fixes and improvements."), ("  \n\t ", "Bug fixes and improvements."),
                           (" " + "ş" * 4100 + "\n", "ş" * 4000), ("x" * 4000, "x" * 4000)):
            self.setUp()
            p = self.dist(note=note)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(self.whats_new(), want, "note %r" % note[:20])

    def test_distribute_internal_only_skips_review(self):
        p = self.dist(groups="other")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.group_adds(), [], "an internal group was POSTed to")
        self.assertIn("internal group other receives builds automatically", p.stdout + p.stderr)
        self.assertEqual(self.review_reqs(), [], "an internal-only distribution touched beta review")

    def test_distribute_groups_are_stripped(self):
        p = self.dist(groups=" other , Friends ")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.group_adds(), ["G-FR"])
        self.assertEqual(len(self.find("POST", "/v1/betaAppReviewSubmissions")), 1)

    def test_distribute_no_matching_group(self):
        p = self.dist(groups="nobody,ghost")
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("no TestFlight group named", p.stderr)
        self.assertIn("the app has", p.stderr)
        for name in ("nobody", "ghost", "bacanaks", "other", "Friends"):
            self.assertIn(name, p.stderr, "the error must list wanted and available names")
        self.assertEqual(self.group_adds(), [])
        self.assertEqual(self.review_reqs(), [])

    def test_distribute_is_idempotent(self):
        self.srv.state["review"] = True
        self.srv.state["fail"][("POST", "/v1/betaGroups/G-EXT/relationships/builds")] = 409
        p = self.dist()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.group_adds(), ["G-EXT"])
        self.assertIn("already", (p.stdout + p.stderr).lower(), "a re-run does not report the existing submission")
        self.assertEqual(len(self.find("GET", "/v1/builds/BUILD-1/betaAppReviewSubmission")), 1)
        self.assertEqual(self.find("POST", "/v1/betaAppReviewSubmissions"), [], "a second submission was posted")

    def test_distribute_group_names_ignore_case(self):
        for groups in ("bacanaks", " BaCaNaKs "):
            self.setUp()
            self.srv.state["groups"] = [("G-INT", "BACANAKS", True), ("G-EXT", "Bacanaks", False), ("G-FR", "Friends", False)]
            p = self.dist(groups=groups)
            self.assertEqual(p.returncode, 0, "%r: %s" % (groups, p.stderr))
            self.assertEqual(self.group_adds(), ["G-EXT"], groups)
            self.assertIn("receives builds automatically", p.stdout + p.stderr, groups)
            self.assertEqual(len(self.find("POST", "/v1/betaAppReviewSubmissions")), 1, groups)

    def test_fake_refuses_internal_group_like_apple(self):
        """Guards the fake: if it stopped refusing, the internal-group tests would prove nothing."""
        import urllib.request, urllib.error
        req = urllib.request.Request(self.api + "/betaGroups/G-INT/relationships/builds", method="POST",
                                     data=b'{"data":[{"type":"builds","id":"BUILD-1"}]}',
                                     headers={"Content-Type": "application/json"})
        with self.assertRaises(urllib.error.HTTPError) as e:
            urllib.request.urlopen(req)
        self.assertEqual(e.exception.code, 422)
        self.assertIn("cannot be assigned to this internal group", e.exception.read().decode())

    def test_distribute_group_add_errors(self):
        for status in (401, 403, 404, 500):
            self.setUp()
            self.srv.state["fail"][("POST", "/v1/betaGroups/G-EXT/relationships/builds")] = status
            p = self.dist()
            self.assertNotEqual(p.returncode, 0, "%d on group add was ignored" % status)

    def test_distribute_review_post_error(self):
        self.srv.state["fail"][("POST", "/v1/betaAppReviewSubmissions")] = 422
        p = self.dist()
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("fake error 422", p.stderr, "the API error body is not shown")
        self.assertIn("Test Information", p.stderr, "no hint about TestFlight Test Information")

    def test_distribute_failed_build_stops_at_once(self):
        for state in ("FAILED", "INVALID"):
            self.setUp()
            self.srv.state["builds"] = ["PROCESSING", state]
            t0 = time.time()
            p = self.dist(ASC_POLL_SECONDS="0.3")
            self.assertNotEqual(p.returncode, 0, state)
            self.assertLess(time.time() - t0, 10)
            self.assertEqual(len(self.find("GET", "/v1/builds")), 2, "%s: polled on" % state)
            self.assertEqual(self.reqs()[-1]["path"], "/v1/builds", "%s: went on after the build failed" % state)

    def test_distribute_deadline(self):
        for states, name in ((["PROCESSING"], "PROCESSING"), ([None], None)):
            self.setUp()
            self.srv.state["builds"] = states
            t0 = time.time()
            p = self.dist(ASC_POLL_SECONDS="1", ASC_POLL_LIMIT_SECONDS="2.5")
            self.assertNotEqual(p.returncode, 0)
            builds = self.find("GET", "/v1/builds")
            self.assertGreaterEqual(len(builds), 2, "gave up before the deadline")
            self.assertLessEqual(self.reqs()[-1]["t"], t0 + 2.5 + 0.5, "a request after the deadline")
            self.assertEqual(self.reqs()[-1]["path"], "/v1/builds")
            if name:
                self.assertIn(name, p.stderr, "the timeout does not name the state")

    def test_distribute_exact_app_only(self):
        self.srv.state["apps"] = [("APP-W", "com.esd.sis.widget")]
        p = self.dist()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.find("GET", "/v1/builds"), [], "a partial bundle id match was used")

    # ---- cleanup: leftovers of earlier runs ---------------------------------------
    @staticmethod
    def ago(hours, form="+0000"):
        """An App Store Connect createdDate `hours` ago, in UTC."""
        t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=hours)
        return t.strftime("%Y-%m-%dT%H:%M:%S.000") + form

    def cleanup(self, *args):
        # A non-UTC zone: an age computed from a naive local time is off by 9 h.
        return self.tool("cleanup", *args, TZ="JST-9")

    def test_cleanup_deletes_only_old_sis_ci_profiles(self):
        self.srv.state["profiles"] = [
            ("P-OLD", "sis ci 5150-1", self.ago(7), ["C-OLD1", "C-OLD2"]),
            ("P-NEW", "sis ci 5151-1", self.ago(5), ["C-NEW"]),  # a run still in flight
            ("P-HAND", "App Store sis", self.ago(500), ["C-HAND"]),
            ("P-MY", "my sis ci 1", self.ago(500), ["C-MY"]),
            ("P-X", "sis cix 1", self.ago(500), ["C-X"]),
            ("P-CASE", "SIS CI 1-1", self.ago(500), ["C-CASE"]),
            # The long-lived identity: never touched, however old.
            ("P-DIST", "sis ci distribution", self.ago(9000), ["C-DIST"]),
            ("P-NODASH", "sis ci 5150", self.ago(500), ["C-ND"]),
            ("P-TAIL", "sis ci 5150-1 old", self.ago(500), ["C-TAIL"]),
            ("P-TRAIL", "sis ci 5150-1 ", self.ago(500), ["C-TRAIL"]),
            ("P-LEAD", " sis ci 5150-1", self.ago(500), ["C-LEAD"]),
            ("P-ALPHA", "sis ci 5150-a", self.ago(500), ["C-ALPHA"]),
            ("P-NL", "sis ci 5150-1\n", self.ago(500), ["C-NL"]),
        ]
        p = self.cleanup()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.deleted(), ["/v1/certificates/C-OLD1", "/v1/certificates/C-OLD2", "/v1/profiles/P-OLD"],
                         "cleanup must delete exactly the sis ci profile older than 6 h and its certificates")
        lists = self.find("GET", "/v1/profiles")
        self.assertTrue(lists, "the profiles were not listed")
        self.assertEqual(lists[0]["query"].get("limit"), ["200"])
        listed = sorted(r["path"] for r in self.reqs("GET") if r["path"].endswith("/certificates"))
        self.assertNotIn("/v1/profiles/P-HAND/certificates", listed)
        for r in self.reqs("DELETE"):
            self.verify_jwt(r["headers"]["authorization"][7:])

    def test_cleanup_age_argument(self):
        for args, created, deleted in ((("0",), self.ago(1 / 60), True), (("24",), self.ago(7), False),
                                       ((), self.ago(6 + 1 / 60), True), ((), self.ago(6 - 1 / 60), False)):
            self.setUp()
            self.srv.state["profiles"] = [("P-1", "sis ci 1-1", created, ["C-1"])]
            p = self.cleanup(*args)
            self.assertEqual(p.returncode, 0, p.stderr)
            want = ["/v1/certificates/C-1", "/v1/profiles/P-1"] if deleted else []
            self.assertEqual(self.deleted(), want, "cleanup %s on a profile created %s" % (args, created))

    def test_cleanup_profile_without_certificate(self):
        self.srv.state["profiles"] = [("P-1", "sis ci 1-1", self.ago(7), [])]
        p = self.cleanup()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.deleted(), ["/v1/profiles/P-1"])

    def test_cleanup_date_forms(self):
        for form in ("Z", "+0000", "+00:00"):
            self.setUp()
            self.srv.state["profiles"] = [("P-1", "sis ci 1-1", self.ago(7, form), ["C-1"]),
                                          ("P-2", "sis ci 2-1", self.ago(5, form), ["C-2"])]
            p = self.cleanup()
            self.assertEqual(p.returncode, 0, "%s: %s" % (form, p.stderr))
            self.assertEqual(self.deleted(), ["/v1/certificates/C-1", "/v1/profiles/P-1"], form)

    def test_cleanup_unparseable_date_fails(self):
        self.srv.state["profiles"] = [("P-1", "sis ci 1-1", "yesterday", ["C-1"])]
        p = self.cleanup()
        self.assertNotEqual(p.returncode, 0, "an unparseable createdDate was accepted")
        self.assertEqual(self.deleted(), [], "a profile of unknown age was deleted")

    def test_cleanup_404_is_fine(self):
        self.srv.state["profiles"] = [("P-1", "sis ci 1-1", self.ago(7), ["C-1"])]
        self.srv.state["fail"].update({("DELETE", "/v1/certificates"): 404, ("DELETE", "/v1/profiles"): 404})
        p = self.cleanup()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.deleted(), ["/v1/certificates/C-1", "/v1/profiles/P-1"])

    def test_cleanup_failed_delete_tries_the_rest(self):
        # A profile is deleted only once all its certificates went; every
        # other delete is still tried; the run then exits 1.
        for path, fault, kept in (("/v1/certificates/C-1", 500, "/v1/profiles/P-1"),
                                  ("/v1/certificates/C-2", "drop", "/v1/profiles/P-1"),
                                  ("/v1/certificates/C-3", "drop", "/v1/profiles/P-2"),
                                  ("/v1/profiles/P-1", 500, None)):
            self.setUp()
            self.srv.state["profiles"] = [("P-1", "sis ci 1-1", self.ago(9), ["C-1", "C-2"]),
                                          ("P-2", "sis ci 2-1", self.ago(8), ["C-3"])]
            self.srv.state["fail"][("DELETE", path)] = fault
            p = self.cleanup()
            self.assertEqual(p.returncode, 1, "%s on %s: want exit 1, got %d" % (fault, path, p.returncode))
            want = [d for d in ["/v1/certificates/C-1", "/v1/certificates/C-2", "/v1/certificates/C-3",
                                "/v1/profiles/P-1", "/v1/profiles/P-2"] if d != kept]
            self.assertEqual(self.deleted(), want, "%s on %s: wrong deletes" % (fault, path))

    def test_cleanup_certificates_before_their_profile(self):
        self.srv.state["profiles"] = [("P-1", "sis ci 1-1", self.ago(9), ["C-1", "C-2"]),
                                      ("P-2", "sis ci 2-1", self.ago(8), ["C-3"])]
        p = self.cleanup()
        self.assertEqual(p.returncode, 0, p.stderr)
        order = [r["path"] for r in self.reqs("DELETE")]
        for prof, certs in (("/v1/profiles/P-1", ["C-1", "C-2"]), ("/v1/profiles/P-2", ["C-3"])):
            for c in certs:
                self.assertLess(order.index("/v1/certificates/" + c), order.index(prof),
                                "%s deleted before its certificate %s: %s" % (prof, c, order))

    def test_cleanup_prints_ids_not_names_or_content(self):
        self.srv.state["profiles"] = [("P-OLD", "sis ci 90817263-4", self.ago(7), ["C-OLD"]),
                                      ("P-NEW", "sis ci 51846029-7", self.ago(1), ["C-NEW"]),
                                      ("P-HAND", "HANDMADE-PROFILE", self.ago(99), ["C-HAND"]),
                                      ("P-DIST", "sis ci distribution", self.ago(99), ["C-DIST"])]
        p = self.cleanup()
        self.assertEqual(p.returncode, 0, p.stderr)
        out = p.stdout + p.stderr
        self.assertIn("P-OLD", out, "the deleted profile's id is not reported")
        self.assertEqual(self.deleted(), ["/v1/certificates/C-OLD", "/v1/profiles/P-OLD"])
        for leak in ("90817263", "51846029", "HANDMADE-PROFILE", "distribution", "Şirket", CONTENT_MARK, CONTENT_MARK[:24]):
            self.assertNotIn(leak, out, "cleanup printed %r" % leak)

    def test_cleanup_bad_usage(self):
        for args in (["abc"], ["1", "2"]):
            self.setUp()
            p = self.tool("cleanup", *args)
            self.assertNotEqual(p.returncode, 0, "cleanup %s accepted" % args)
            self.assertFalse(self.reqs(), "cleanup %s made a request" % args)
            self.assertIn("cleanup", p.stdout + p.stderr, "cleanup %s does not show the usage" % args)

    # ---- fetch: the long-lived identity every run signs with ----------------------
    WARN = re.compile(r"^::warning::The iOS signing (certificate|profile) expires in (\d+) days; "
                      r"rotate it \(docs/DELIVERY\.md\)$")

    @staticmethod
    def until(days, form="+0000"):
        """An App Store Connect expirationDate `days` from now, in UTC."""
        t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=days)
        return t.strftime("%Y-%m-%dT%H:%M:%S.000") + form

    def identity(self, profiles, certs=None):
        """profiles: (id, name, created, state, [cert ids], expirationDate or None);
        certs: {id: attribute overrides}. Each profile and certificate has its own content."""
        st = self.srv.state
        st["profiles"] = [(i, n, c, cs) for i, n, c, _, cs, _ in profiles]
        for i, _, _, state, _, exp in profiles:
            st["pattrs"][i] = {"profileState": state, "expirationDate": exp,
                               "profileContent": base64.b64encode(PROFILE_BYTES + i.encode()).decode()}
        for _, _, _, _, cs, _ in profiles:
            for c in cs:
                st["cattrs"][c] = dict({"expirationDate": self.until(300),
                                        "certificateContent": base64.b64encode(self.cert_der + c.encode()).decode()},
                                       **(certs or {}).get(c, {}))

    def healthy(self, cert_exp=300, prof_exp=300):
        self.identity([("P-D", "sis ci distribution", self.ago(240), "ACTIVE", ["C-D"],
                        None if prof_exp is None else self.until(prof_exp))],
                      {"C-D": {"expirationDate": None if cert_exp is None else self.until(cert_exp)}})

    def fetch(self, name="sis ci distribution"):
        out = tempfile.mkdtemp()
        # A non-UTC zone: days left computed from a naive local time are off by 9 h.
        p = self.tool("fetch", name, out, TZ="JST-9")
        self.assertEqual({r["method"] for r in self.reqs()} - {"GET"}, set(), "fetch must only read")
        return p, out

    def ids(self, p):
        return sorted(l for l in p.stdout.splitlines() if not l.startswith("::warning::"))

    def warnings(self, p):
        return [self.WARN.match(l).groups() for l in (p.stdout + p.stderr).splitlines() if self.WARN.match(l)]

    def written(self, out):
        with open(os.path.join(out, "cert.cer"), "rb") as f, open(os.path.join(out, "profile.mobileprovision"), "rb") as g:
            return f.read(), g.read()

    def test_fetch_writes_identity_prints_ids(self):
        self.healthy()
        p, out = self.fetch()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ids(p), ["SIGNING_CERTIFICATE_ID=C-D", "SIGNING_PROFILE_ID=P-D"],
                         "stdout must be exactly the two id lines")
        self.assertEqual(self.warnings(p), [])
        self.assertEqual(self.written(out), (self.cert_der + b"C-D", PROFILE_BYTES + b"P-D"))
        lists = self.find("GET", "/v1/profiles")
        self.assertEqual(len(lists), 1)
        self.assertEqual(lists[0]["query"].get("filter[name]"), ["sis ci distribution"])
        self.assertEqual(lists[0]["query"].get("limit"), ["200"])
        self.assertEqual(len(self.find("GET", "/v1/profiles/P-D/certificates")), 1)
        for r in self.reqs():
            self.verify_jwt(r["headers"]["authorization"][7:])
        out_text = p.stdout + p.stderr
        for leak in ("sis ci distribution", "Şirket", "Apple Distribution",
                     base64.b64encode(self.cert_der + b"C-D").decode()[:40],
                     base64.b64encode(PROFILE_BYTES + b"P-D").decode()[:40], "UUID-P-D"):
            self.assertNotIn(leak, out_text, "fetch printed %r" % leak)

    def test_fetch_picks_exact_active_newest(self):
        # The list is in no date order: neither the first nor the last is the newest.
        self.identity([
            ("P-MID", "sis ci distribution", self.ago(24 * 30), "ACTIVE", ["C-MID"], self.until(300)),
            ("P-NEW", "sis ci distribution", self.ago(24 * 2), "ACTIVE", ["C-NEW"], self.until(300)),
            ("P-OLD", "sis ci distribution", self.ago(24 * 400), "ACTIVE", ["C-OLD"], self.until(300)),
            ("P-INV", "sis ci distribution", self.ago(1), "INVALID", ["C-INV"], self.until(300)),
            ("P-LONG", "sis ci distribution 2", self.ago(1), "ACTIVE", ["C-LONG"], self.until(300)),
            ("P-PRE", "old sis ci distribution", self.ago(1), "ACTIVE", ["C-PRE"], self.until(300)),
            ("P-CASE", "SIS CI DISTRIBUTION", self.ago(1), "ACTIVE", ["C-CASE"], self.until(300)),
            ("P-SP", "sis ci distribution ", self.ago(1), "ACTIVE", ["C-SP"], self.until(300)),
        ])
        p, out = self.fetch()
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.ids(p), ["SIGNING_CERTIFICATE_ID=C-NEW", "SIGNING_PROFILE_ID=P-NEW"])
        self.assertEqual(self.written(out), (self.cert_der + b"C-NEW", PROFILE_BYTES + b"P-NEW"))

    def test_fetch_certificate_choice(self):
        for certs, types, want in ((["C-DEV", "C-NOTYPE", "C-DIST"], {"C-DEV": "DEVELOPMENT", "C-NOTYPE": None}, "C-NOTYPE"),
                                   (["C-DEV", "C-DIST", "C-DIST2"], {"C-DEV": "IOS_DEVELOPMENT"}, "C-DIST")):
            self.setUp()
            self.identity([("P-D", "sis ci distribution", self.ago(240), "ACTIVE", certs, self.until(300))],
                          {c: {"certificateType": t} for c, t in types.items()})
            p, out = self.fetch()
            self.assertEqual(p.returncode, 0, "%s: %s" % (certs, p.stderr))
            self.assertEqual(self.ids(p), ["SIGNING_CERTIFICATE_ID=" + want, "SIGNING_PROFILE_ID=P-D"], certs)
            self.assertEqual(self.written(out)[0], self.cert_der + want.encode(), certs)

    def test_fetch_no_active_profile(self):
        for profiles in ([],
                         [("P-INV", "sis ci distribution", self.ago(1), "INVALID", ["C-1"], self.until(300))],
                         [("P-LONG", "sis ci distribution 2", self.ago(1), "ACTIVE", ["C-1"], self.until(300)),
                          ("P-CASE", "SIS CI DISTRIBUTION", self.ago(1), "ACTIVE", ["C-2"], self.until(300))]):
            self.setUp()
            self.identity(profiles)
            p, out = self.fetch()
            self.assertNotEqual(p.returncode, 0, "%s accepted" % [x[:2] for x in profiles])
            self.assertIn("no active profile named", p.stdout + p.stderr)
            self.assertIn("run the iOS signing bootstrap workflow", p.stdout + p.stderr)
            self.assertNotIn("SIGNING_", p.stdout)

    def test_fetch_no_distribution_certificate(self):
        for certs, types in (([], {}), (["C-DEV"], {"C-DEV": "DEVELOPMENT"})):
            self.setUp()
            self.identity([("P-D", "sis ci distribution", self.ago(240), "ACTIVE", certs, self.until(300))],
                          {c: {"certificateType": t} for c, t in types.items()})
            p, out = self.fetch()
            self.assertNotEqual(p.returncode, 0, "a profile with certificates %s was accepted" % certs)
            self.assertNotIn("SIGNING_CERTIFICATE_ID", p.stdout)

    def test_fetch_expired(self):
        for cert_exp, prof_exp, what in ((-1, 300, "certificate"), (300, -1, "profile"), (-0.1, 300, "certificate")):
            self.setUp()
            self.healthy(cert_exp, prof_exp)
            p, out = self.fetch()
            self.assertEqual(p.returncode, 1, "%s %s days: want exit 1, got %d" % (what, cert_exp, p.returncode))
            self.assertIn("the signing %s expired; rotate it (docs/DELIVERY.md)" % what, p.stdout + p.stderr)

    def test_fetch_expiry_warning(self):
        for cert_exp, prof_exp, want in (
                (10 + 1 / 24, 300, [("certificate", (10, 11))]),
                (300, 10 + 1 / 24, [("profile", (10, 11))]),
                (28.5, 28.5, [("certificate", (28, 29)), ("profile", (28, 29))]),
                (31.5, 31.5, []), (None, None, []), (300, None, []),
                # Under JST-9: 30 days and 4 hours is not < 30 days; a naive local "now" makes it 29.8.
                (30 + 4 / 24, 30 + 4 / 24, [])):
            self.setUp()
            self.healthy(cert_exp, prof_exp)
            p, out = self.fetch()
            self.assertEqual(p.returncode, 0, "cert %s / profile %s days: %s" % (cert_exp, prof_exp, p.stderr))
            got = self.warnings(p)
            self.assertEqual(sorted(w for w, _ in got), [w for w, _ in want], "cert %s / profile %s days: %s"
                             % (cert_exp, prof_exp, p.stdout + p.stderr))
            for (w, n), (_, ok) in zip(sorted(got), want):
                self.assertIn(int(n), ok, "%s: %s days" % (w, n))
            self.assertEqual(self.ids(p), ["SIGNING_CERTIFICATE_ID=C-D", "SIGNING_PROFILE_ID=P-D"])

    def test_fetch_date_forms(self):
        for form in ("Z", "+0000", "+00:00"):
            self.setUp()
            self.identity([("P-D", "sis ci distribution", self.ago(240, form), "ACTIVE", ["C-D"], self.until(10.5, form))],
                          {"C-D": {"expirationDate": self.until(-1, form)}})
            p, out = self.fetch()
            self.assertEqual(p.returncode, 1, "%s: an expired certificate passed" % form)

    def test_fetch_api_errors(self):
        for key, fault in ((("GET", "/v1/profiles"), 500), (("GET", "/v1/profiles"), 401),
                           (("GET", "/v1/profiles/P-D/certificates"), 500), (("GET", "/v1/profiles/P-D/certificates"), "drop")):
            self.setUp()
            self.healthy()
            self.srv.state["fail"][key] = fault
            p, out = self.fetch()
            self.assertNotEqual(p.returncode, 0, "%s on %s accepted" % (fault, key[1]))
            self.assertNotIn("SIGNING_CERTIFICATE_ID", p.stdout)
            self.assertNotIn("Traceback", p.stderr)

    def test_fetch_bad_usage(self):
        for args in (["fetch"], ["fetch", "sis ci distribution"], ["fetch", "sis ci distribution", "/tmp", "x"]):
            self.setUp()
            p = self.tool(*args)
            self.assertNotEqual(p.returncode, 0, "%s accepted" % args)
            self.assertFalse(self.reqs(), "%s made a request" % args)
            self.assertIn("fetch PROFILE_NAME OUT_DIR", p.stdout + p.stderr, "%s does not show the usage" % args)

if __name__ == "__main__":
    unittest.main(verbosity=1)
