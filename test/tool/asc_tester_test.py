#!/usr/bin/env python3
"""tool/asc_signing.py tester add|remove GROUPS against a fake App Store Connect.

Reuses the fake API of asc_signing_test.py and adds the beta tester routes,
answering like App Store Connect: GET /v1/betaTesters?filter[email]= (200,
a list), POST /v1/betaTesters (201; 409 when the email is a tester already),
attaching to groups from either side (204), DELETE
/v1/betaTesters/{id}/relationships/apps (204; 404 when not in the app).

Contract:
  - the email comes only from $TESTER_EMAIL; none -> exit 2.
  - add: looks the tester up first; then creates it in, or attaches it to,
    only the EXTERNAL groups named in GROUPS; never user invitations.
  - remove: DELETE /v1/betaTesters/{id}/relationships/apps; not a tester, or
    a 404 (not in this app), is success; any other 4xx is an error.
  - errors print only "HTTP <status|-> <code>": no path, query, body, email.
  - exit 75 transient (no status, 429, >= 500), 1 permanent.
"""
import os
import re
import subprocess
import sys
import tempfile
import unittest
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asc_signing_test as base  # noqa: E402  (module import: its tests are not collected here)

EMAIL = "tess.ter+qa@mail.test"
OTHER = "someone.else@mail.test"
ERROR_LINE = re.compile(r"\AHTTP (\d{3}|-) [A-Za-z0-9_.\-]+\n?\Z")


class TesterFake(base.Fake):
    """The base fake plus Apple's beta tester routes."""

    def handle_any(self):
        path = urllib.parse.urlsplit(self.path).path
        tester_route = (path.startswith("/v1/betaTesters") or path.startswith("/v1/userInvitations")
                        or path.startswith("/v1/users")
                        or re.fullmatch(r"/v1/betaGroups/[^/]+/relationships/betaTesters", path))
        if not tester_route:
            return super().handle_any()
        st = self.server.state
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        body = base.json.loads(raw) if raw else None
        url = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(url.query)
        st["requests"].append({"method": self.command, "path": path, "query": q, "body": body,
                               "headers": {k.lower(): v for k, v in self.headers.items()}})
        forced = st["fail"].get((self.command, path)) or st["fail"].get((self.command, path.rsplit("/", 2)[0]))
        if forced == "drop":
            self.close_connection = True
            self.connection.shutdown(base.socket.SHUT_RDWR)
            return
        if forced:
            return self.error(forced)
        testers = st["testers"]  # id -> {"email", "apps": set, "groups": set}
        groups = {g[0] for g in st["groups"]}
        if (self.command, path) == ("GET", "/v1/betaTesters"):
            want = q.get("filter[email]", [None])[0]
            data = [{"type": "betaTesters", "id": i, "attributes": {"email": t["email"], "firstName": "Q",
                                                                      "lastName": "A", "inviteType": "EMAIL"}}
                    for i, t in testers.items() if want is not None and t["email"] == want]
            return self.reply(200, {"data": data, "links": {"self": self.path}, "meta": {"paging": {"total": len(data)}}})
        if (self.command, path) == ("POST", "/v1/betaTesters"):
            d = (body or {}).get("data", {})
            email = d.get("attributes", {}).get("email")
            gids = [g.get("id") for g in d.get("relationships", {}).get("betaGroups", {}).get("data", [])]
            if not email or not gids:
                return self.error(422)
            if any(g not in groups for g in gids):
                return self.error(404)
            if any(t["email"] == email for t in testers.values()):
                return self.reply(409, {"errors": [{"status": "409", "code": "ENTITY_ERROR.ATTRIBUTE.UNIQUE",
                                                    "detail": "A tester with this email already exists."}]})
            tid = "T-NEW%d" % len(testers)
            testers[tid] = {"email": email, "apps": {"APP-1"}, "groups": set(gids)}
            return self.reply(201, {"data": {"type": "betaTesters", "id": tid, "attributes": {"email": email}}})
        m = re.fullmatch(r"/v1/betaGroups/([^/]+)/relationships/betaTesters", path)
        if m and self.command == "POST":
            if m.group(1) not in groups:
                return self.error(404)
            for t in (body or {}).get("data", []):
                if t.get("id") not in testers:
                    return self.error(404)
                testers[t["id"]]["groups"].add(m.group(1))
                testers[t["id"]]["apps"].add("APP-1")
            return self.reply(204)
        m = re.fullmatch(r"/v1/betaTesters/([^/]+)/relationships/betaGroups", path)
        if m and self.command == "POST":
            if m.group(1) not in testers:
                return self.error(404)
            for g in (body or {}).get("data", []):
                if g.get("id") not in groups:
                    return self.error(404)
                testers[m.group(1)]["groups"].add(g["id"])
                testers[m.group(1)]["apps"].add("APP-1")
            return self.reply(204)
        m = re.fullmatch(r"/v1/betaTesters/([^/]+)/relationships/apps", path)
        if m and self.command == "DELETE":
            t = testers.get(m.group(1))
            apps = [a.get("id") for a in (body or {}).get("data", [])]
            if t is None or not apps or any(a not in t["apps"] for a in apps):
                return self.error(404)
            t["apps"] -= set(apps)
            t["groups"].clear()
            return self.reply(204)
        return self.error(404)

    do_GET = do_POST = do_DELETE = do_PATCH = handle_any


class TesterTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.keys = os.path.join(cls.tmp, "keys")
        os.mkdir(cls.keys)
        p8 = os.path.join(cls.keys, "AuthKey_%s.p8" % base.KEY_ID)
        base.sh("openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", p8)
        cls.srv = base.http.server.ThreadingHTTPServer(("127.0.0.1", 0), TesterFake)
        base.threading.Thread(target=cls.srv.serve_forever, daemon=True).start()
        cls.api = "http://127.0.0.1:%d/v1" % cls.srv.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.srv.shutdown()
        cls.srv.server_close()

    def setUp(self):
        self.srv.state = {"requests": [], "fail": {}, "testers": {
            "T-OTHER": {"email": OTHER, "apps": {"APP-1"}, "groups": {"G-EXT"}}},
            "apps": [("APP-W", "com.esd.sis.widget"), ("APP-1", "com.esd.sis"), ("APP-X", "com.other.app")],
            "groups": [("G-INT", "bacanaks", True), ("G-EXT", "bacanaks", False), ("G-OTHER", "other", True),
                       ("G-OLD", "bacanaks-old", False), ("G-FR", "Friends", False)]}

    def run_tool(self, *args, email=EMAIL):
        env = dict(os.environ, API_PRIVATE_KEYS_DIR=self.keys, KEY_ID=base.KEY_ID, ISSUER_ID=base.ISSUER)
        env.pop("TESTER_EMAIL", None)
        if email is not None:
            env["TESTER_EMAIL"] = email
        code = ("import sys; sys.path.insert(0, %r); import asc_signing as a; a.API = sys.argv[1]; "
                "a.main(['asc_signing.py'] + sys.argv[2:])" % os.path.dirname(base.TOOL))
        p = subprocess.run([sys.executable, "-c", code, self.api, *args], env=env,
                           capture_output=True, text=True, timeout=60)
        out = p.stdout + p.stderr
        for leak in (EMAIL, "tess.ter", "/v1/", "filter", "fake error", "errors", "T-NEW", "T-OLD"):
            self.assertNotIn(leak, out, "the output leaks %r: %r" % (leak, out))
        return p

    def reqs_of(self, method=None, prefix="/v1/betaTesters"):
        return [r for r in self.srv.state["requests"]
                if r["path"].startswith(prefix) and method in (None, r["method"])]

    def group_ids_used(self, tid=None):
        """Every group the run put a tester in, from either side of the relationship."""
        used = set()
        for r in self.srv.state["requests"]:
            if r["method"] != "POST" or not r["body"]:
                continue
            if r["path"] == "/v1/betaTesters":
                used |= {g["id"] for g in r["body"]["data"].get("relationships", {}).get("betaGroups", {}).get("data", [])}
            m = re.fullmatch(r"/v1/betaGroups/([^/]+)/relationships/betaTesters", r["path"])
            if m:
                used.add(m.group(1))
            if re.fullmatch(r"/v1/betaTesters/[^/]+/relationships/betaGroups", r["path"]):
                used |= {g["id"] for g in r["body"]["data"]}
        return used

    def assert_error_line(self, p, code):
        self.assertEqual(p.returncode, code, p.stderr)
        self.assertRegex(p.stderr, ERROR_LINE, "errors print only 'HTTP <status|-> <code>'")

    def add_existing(self):
        self.srv.state["testers"]["T-OLD"] = {"email": EMAIL, "apps": set(), "groups": set()}

    # --- the email -----------------------------------------------------------

    def test_no_tester_email_is_exit_2_and_no_call(self):
        for action in ("add", "remove"):
            for email in (None, ""):
                self.srv.state["requests"].clear()
                p = self.run_tool("tester", action, "bacanaks", email=email)
                self.assertEqual(p.returncode, 2, "%s with TESTER_EMAIL=%r: %s" % (action, email, p.stderr))
                self.assertEqual(self.reqs_of(), [], "nothing is called without the email")

    def test_the_email_is_never_taken_from_argv(self):
        p = self.run_tool("tester", "add", "bacanaks", EMAIL, email=None)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.reqs_of("POST"), [], "an email in argv is not used")

    # --- add -----------------------------------------------------------------

    def test_add_new_tester_looks_up_first_then_creates_in_the_external_group_only(self):
        p = self.run_tool("tester", "add", "bacanaks")
        self.assertEqual(p.returncode, 0, p.stderr)
        reqs = self.reqs_of()
        self.assertEqual((reqs[0]["method"], reqs[0]["path"]), ("GET", "/v1/betaTesters"), "the lookup comes first")
        self.assertEqual(reqs[0]["query"].get("filter[email]"), [EMAIL])
        creates = self.reqs_of("POST", "/v1/betaTesters")
        created = [r for r in creates if r["path"] == "/v1/betaTesters"]
        self.assertEqual(len(created), 1, "one create")
        self.assertEqual(created[0]["body"]["data"]["attributes"]["email"], EMAIL)
        self.assertEqual(self.group_ids_used(), {"G-EXT"}, "only the external group named bacanaks")
        new = [t for t in self.srv.state["testers"].values() if t["email"] == EMAIL]
        self.assertEqual(len(new), 1)
        self.assertEqual(new[0]["groups"], {"G-EXT"})

    def test_add_several_groups_uses_each_external_one(self):
        p = self.run_tool("tester", "add", "bacanaks,Friends")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.group_ids_used(), {"G-EXT", "G-FR"})

    def test_add_existing_tester_attaches_and_does_not_create(self):
        self.add_existing()
        p = self.run_tool("tester", "add", "bacanaks")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual([r for r in self.reqs_of("POST") if r["path"] == "/v1/betaTesters"], [], "no create")
        self.assertEqual(self.group_ids_used(), {"G-EXT"})
        self.assertEqual(self.srv.state["testers"]["T-OLD"]["groups"], {"G-EXT"})
        self.assertEqual(self.srv.state["testers"]["T-OTHER"]["groups"], {"G-EXT"}, "another tester untouched")

    def test_add_never_uses_an_internal_group(self):
        p = self.run_tool("tester", "add", "other")
        self.assertNotEqual(p.returncode, 0, "no external group named 'other': nothing to add to")
        self.assertEqual(self.group_ids_used(), set(), "the internal group is never used")
        self.assertFalse([t for t in self.srv.state["testers"].values() if t["email"] == EMAIL])

    def test_add_never_calls_user_invitations(self):
        for setup in (lambda: None, self.add_existing):
            setup()
            self.run_tool("tester", "add", "bacanaks")
        self.assertEqual([r for r in self.srv.state["requests"]
                          if r["path"].startswith(("/v1/userInvitations", "/v1/users"))], [])

    def test_add_permanent_errors_exit_1(self):
        for key, status in ((("POST", "/v1/betaTesters"), 409), (("POST", "/v1/betaTesters"), 403),
                            (("GET", "/v1/betaTesters"), 401)):
            with self.subTest(key=key, status=status):
                self.setUp()
                self.srv.state["fail"][key] = status
                self.assert_error_line(self.run_tool("tester", "add", "bacanaks"), 1)

    def test_add_attach_refused_exits_1(self):
        # A 404 while attaching is not "not in this app or group": it escalates.
        self.add_existing()
        self.srv.state["fail"][("POST", "/v1/betaGroups/G-EXT/relationships/betaTesters")] = 404
        self.srv.state["fail"][("POST", "/v1/betaTesters/T-OLD/relationships/betaGroups")] = 404
        self.assert_error_line(self.run_tool("tester", "add", "bacanaks"), 1)

    def test_add_transient_errors_exit_75(self):
        for key, status in ((("GET", "/v1/betaTesters"), 429), (("GET", "/v1/betaTesters"), 500),
                            (("POST", "/v1/betaTesters"), 503), (("GET", "/v1/betaTesters"), "drop")):
            with self.subTest(key=key, status=status):
                self.setUp()
                self.srv.state["fail"][key] = status
                p = self.run_tool("tester", "add", "bacanaks")
                self.assert_error_line(p, 75)
                if status == "drop":
                    self.assertTrue(p.stderr.startswith("HTTP - "), "no status: '-': %r" % p.stderr)
                else:
                    self.assertTrue(p.stderr.startswith("HTTP %s " % status), p.stderr)

    # --- remove --------------------------------------------------------------

    def test_remove_deletes_the_app_relationship(self):
        self.add_existing()
        self.srv.state["testers"]["T-OLD"].update(apps={"APP-1"}, groups={"G-EXT"})
        p = self.run_tool("tester", "remove", "bacanaks")
        self.assertEqual(p.returncode, 0, p.stderr)
        reqs = self.reqs_of()
        self.assertEqual((reqs[0]["method"], reqs[0]["path"]), ("GET", "/v1/betaTesters"), "the lookup comes first")
        dels = self.reqs_of("DELETE")
        self.assertEqual([r["path"] for r in dels], ["/v1/betaTesters/T-OLD/relationships/apps"])
        self.assertEqual(dels[0]["body"]["data"], [{"type": "apps", "id": "APP-1"}], "this app, exactly")
        self.assertEqual(self.srv.state["testers"]["T-OLD"]["apps"], set())
        self.assertEqual(self.srv.state["testers"]["T-OTHER"]["apps"], {"APP-1"}, "another tester untouched")

    def test_remove_not_a_tester_is_success_without_delete(self):
        p = self.run_tool("tester", "remove", "bacanaks")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.reqs_of("DELETE"), [])

    def test_remove_not_in_this_app_404_is_success(self):
        self.add_existing()  # a tester, but of no group of this app
        p = self.run_tool("tester", "remove", "bacanaks")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(len(self.reqs_of("DELETE")), 1)

    def test_remove_other_4xx_escalates(self):
        for status in (403, 409, 422, 401):
            with self.subTest(status=status):
                self.setUp()
                self.add_existing()
                self.srv.state["fail"][("DELETE", "/v1/betaTesters/T-OLD/relationships/apps")] = status
                p = self.run_tool("tester", "remove", "bacanaks")
                self.assert_error_line(p, 1)
                self.assertTrue(p.stderr.startswith("HTTP %d " % status), p.stderr)

    def test_remove_transient_errors_exit_75(self):
        for key, status in ((("DELETE", "/v1/betaTesters/T-OLD/relationships/apps"), 429),
                            (("DELETE", "/v1/betaTesters/T-OLD/relationships/apps"), 502),
                            (("DELETE", "/v1/betaTesters/T-OLD/relationships/apps"), "drop"),
                            (("GET", "/v1/betaTesters"), 500)):
            with self.subTest(key=key, status=status):
                self.setUp()
                self.add_existing()
                self.srv.state["testers"]["T-OLD"]["apps"] = {"APP-1"}
                self.srv.state["fail"][key] = status
                self.assert_error_line(self.run_tool("tester", "remove", "bacanaks"), 75)


if __name__ == "__main__":
    unittest.main()
