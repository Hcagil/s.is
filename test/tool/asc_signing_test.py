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
        self.srv.state = {"requests": [], "fail": {}, "cert_der": self.cert_der,
                          "apps": [("APP-W", "com.esd.sis.widget"), ("APP-1", "com.esd.sis"), ("APP-X", "com.other.app")],
                          "version": "412", "builds": ["VALID"], "locs": [("L-DE", "de-DE"), ("L-EN", "en-US")],
                          "groups": [("G-INT", "bacanaks", True), ("G-EXT", "bacanaks", False), ("G-OTHER", "other", True),
                                     ("G-OLD", "bacanaks-old", False), ("G-FR", "Friends", False)],
                          "review": False}

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
                     ["distribute", "com.esd.sis", "412", "bacanaks"],
                     ["distribute", "com.esd.sis", "412", "bacanaks", "note", "extra"]):
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

    def test_delete_profile_failure_still_revokes_certificate(self):
        # A failing delete must not leave the other one behind, and still fails the run.
        for path, fault in (("/v1/profiles/PROF-9", 500), ("/v1/profiles/PROF-9", "drop"),
                            ("/v1/certificates/CERT-9", 500), ("/v1/certificates/CERT-9", "drop")):
            self.setUp()
            self.srv.state["fail"][("DELETE", path)] = fault
            p = self.tool("delete", "CERT-9", "PROF-9")
            self.assertNotEqual(p.returncode, 0, "%s on %s was ignored" % (fault, path))
            self.assertEqual(self.deleted(), ["/v1/certificates/CERT-9", "/v1/profiles/PROF-9"],
                             "%s on %s stopped the other delete" % (fault, path))

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


if __name__ == "__main__":
    unittest.main(verbosity=1)
