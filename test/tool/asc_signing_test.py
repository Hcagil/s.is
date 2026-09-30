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
          OUT/profile.mobileprovision; stdout carries only GITHUB_ENV lines
          SIGNING_CERTIFICATE_ID / SIGNING_PROFILE_ID. A failure after the
          certificate exists still reports its id (the always() revoke step
          reads it) and exits non-zero.
  delete  CERT_ID PROFILE_ID: deletes both; `-` skips one; 404 is fine; any
          other error fails.
  never   prints the private key or the bearer token.

Needs python3 and openssl only.
"""
import base64
import http.server
import json
import os
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
        key = (self.command, url.path)
        forced = st["fail"].get(key) or st["fail"].get((self.command, url.path.rsplit("/", 1)[0]))
        if forced:
            return self.error(forced)
        if key == ("GET", "/v1/bundleIds"):
            f = urllib.parse.parse_qs(url.query).get("filter[identifier]", [""])[0]
            data = [{"type": "bundleIds", "id": i, "attributes": {"identifier": v, "platform": "IOS"}}
                    for i, v in BUNDLES.items() if f in v]
            return self.reply(200, {"data": data, "links": {"self": self.path}, "meta": {"paging": {"total": len(data)}}})
        if key == ("POST", "/v1/certificates"):
            return self.reply(201, {"data": {"type": "certificates", "id": "CERT-1", "attributes": {
                "certificateType": "DISTRIBUTION", "name": "Apple Distribution: Şirket",
                "certificateContent": base64.b64encode(st["cert_der"]).decode()}}})
        if key == ("POST", "/v1/profiles"):
            return self.reply(201, {"data": {"type": "profiles", "id": "PROF-1", "attributes": {
                "profileType": "IOS_APP_STORE", "uuid": "0F1E2D3C-UUID",
                "profileContent": base64.b64encode(PROFILE_BYTES).decode()}}})
        if self.command == "DELETE" and url.path.rsplit("/", 1)[0] in ("/v1/certificates", "/v1/profiles"):
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
        self.srv.state = {"requests": [], "fail": {}, "cert_der": self.cert_der}

    def tool(self, *args, code="a.main(['asc_signing.py'] + sys.argv[2:])"):
        """Runs the tool in its own process with only API redirected."""
        env = dict(os.environ, API_PRIVATE_KEYS_DIR=self.keys, KEY_ID=KEY_ID, ISSUER_ID=ISSUER)
        prog = ("import sys; sys.path.insert(0, %r); import asc_signing as a; a.API = sys.argv[1]; " % os.path.dirname(TOOL)) + code
        p = subprocess.run([sys.executable, "-c", prog, self.api, *args], env=env, capture_output=True, text=True, timeout=60)
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
        for args in ([], ["create", self.csr, "com.esd.sis", "n"], ["delete", "C"], ["revoke", "C", "P"]):
            self.setUp()
            p = self.tool(*args)
            self.assertNotEqual(p.returncode, 0, "usage %s accepted" % args)
            self.assertFalse(self.reqs(), "usage %s made a request" % args)

    # ---- delete -----------------------------------------------------------------
    def deleted(self):
        return sorted(r["path"] for r in self.reqs("DELETE"))

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


if __name__ == "__main__":
    unittest.main(verbosity=1)
