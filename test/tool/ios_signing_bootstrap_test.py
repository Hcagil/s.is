#!/usr/bin/env python3
"""The one-time creation of the long-lived iOS distribution certificate.

.github/workflows/ios-signing-bootstrap.yml: its shell steps are lifted out
of the file (not copied) and run in the file's order with GitHub's if: gates,
against a stand-in for tool/asc_signing.py and the real openssl:
  - workflow_dispatch only; inputs csr_b64 (required) and profile_name
    (default 'sis ci distribution'); contents: read; an unpersisted checkout;
  - it sees only the three App Store Connect secrets and never
    IOS_DISTRIBUTION_KEY (the private key never reaches GitHub Actions);
  - no ${{ }} inside a run script; no tracing;
  - sweeps `asc_signing.py cleanup` before it creates anything; refuses a
    csr_b64 that is not a CSR before any create; creates (create CSR
    com.esd.sis PROFILE_NAME DIR) and fails when the issued certificate's
    public key is not the CSR's; logs only the ids and the certificate's end
    date; the key is removed if: always().

tool/ios_signing_bootstrap.sh [GIT_REF] [PROFILE_NAME], against stand-ins for
gh, docker and sleep (the key and CSR are really generated, by openssl, in a
private temporary directory standing in for the container's mount):
  - dispatches the workflow with the CSR only (csr_b64, profile_name; default
    'sis ci distribution') on GIT_REF; waits for that run (not an older one);
  - only after it succeeded: `gh secret set IOS_DISTRIBUTION_KEY` with the key
    on stdin (never in an argument), the key matching the CSR sent;
  - the key is never printed; the temporary directory (700, key 600) is gone
    afterwards, whatever failed; a failed run, a run that never appears, a key
    that could not be made or gh signed out store nothing.

Needs python3, openssl and jq (gh's --jq is evaluated with jq).
"""
import base64
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
WF = os.path.join(ROOT, ".github", "workflows", "ios-signing-bootstrap.yml")
SCRIPT = os.path.join(ROOT, "tool", "ios_signing_bootstrap.sh")
ASC_SECRETS = {"APP_STORE_CONNECT_API_KEY", "APP_STORE_CONNECT_KEY_ID", "APP_STORE_CONNECT_ISSUER_ID"}
ASC_KEY = "-----BEGIN PRIVATE KEY-----\nMIGTAgEAMBMGByqGSM49AgEGCCqGSM49ASCSECRETASCSECRET\n-----END PRIVATE KEY-----"


def sh(*cmd, data=None):
    return subprocess.run(cmd, input=data, capture_output=True, check=True).stdout


def pubkey(path, kind):
    args = {"key": ["pkey", "-in", path, "-pubout"], "csr": ["req", "-in", path, "-pubkey", "-noout"],
            "cert": ["x509", "-inform", "der", "-in", path, "-pubkey", "-noout"]}[kind]
    return sh("openssl", *args)


# ---- the workflow file, read as GitHub reads it (indentation-based) -------------
def wf_lines():
    with open(WF) as f:
        return f.read().splitlines()


def block(lines, header, indent):
    """The lines under `header` (at `indent`) that are indented deeper."""
    out, on = [], False
    for l in lines:
        if on:
            if l.strip() and len(l) - len(l.lstrip()) <= indent:
                break
            out.append(l)
        elif l == " " * indent + header:
            on = True
    return out


def mapping(lines, indent):
    return {l.strip().split(":", 1)[0]: l.split(":", 1)[1].strip() for l in lines
            if l.strip() and len(l) - len(l.lstrip()) == indent and ":" in l}


def steps():
    """Each step of the one job: name, if, env, run, uses."""
    out, cur, run_ind = [], None, None
    lines = block(wf_lines(), "steps:", 4)
    i = 0
    while i < len(lines):
        l = lines[i]
        ind = len(l) - len(l.lstrip())
        if l.startswith("      - "):
            cur = {"name": None, "if": "", "env": {}, "run": None, "uses": None}
            out.append(cur)
            l = "        " + l[8:]
            ind = 8
        if ind == 8 and ":" in l:
            k, v = l.strip().split(":", 1)
            v = v.strip()
            if k == "run" and v == "|":
                body = []
                i += 1
                while i < len(lines) and (not lines[i].strip() or len(lines[i]) - len(lines[i].lstrip()) > 8):
                    body.append(lines[i])
                    i += 1
                strip = min(len(b) - len(b.lstrip()) for b in body if b.strip())
                cur["run"] = "\n".join(b[strip:] for b in body) + "\n"
                continue
            if k == "env":
                i += 1
                while i < len(lines) and len(lines[i]) - len(lines[i].lstrip()) > 8:
                    ek, ev = lines[i].strip().split(":", 1)
                    cur["env"][ek] = ev.strip()
                    i += 1
                continue
            if k in cur:
                cur[k] = v
        i += 1
    return out


class WorkflowTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.bin = os.path.join(self.tmp, "bin")
        os.mkdir(self.bin)
        # A CSR from a key that stays here; another key for a certificate that is not the CSR's.
        self.csr = os.path.join(self.tmp, "csr.pem")
        sh("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", os.path.join(self.tmp, "k.pem"),
           "-out", self.csr, "-subj", "/CN=sis distribution")
        sh("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", os.path.join(self.tmp, "other.pem"),
           "-out", os.path.join(self.tmp, "other.csr"), "-subj", "/CN=other")
        self.ca = os.path.join(self.tmp, "ca")
        sh("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", self.ca + ".key", "-out", self.ca + ".pem",
           "-subj", "/CN=Test WWDR", "-days", "2")
        with open(self.csr, "rb") as f:
            self.csr_pem = f.read()
        self.calls = os.path.join(self.tmp, "calls")
        # tool/asc_signing.py stood in for: App Store Connect's side (its own test is asc_signing_test.py).
        stub = os.path.join(self.bin, "asc_signing.py")
        with open(stub, "w") as f:
            f.write(r'''#!/usr/bin/env python3
import json, os, subprocess, sys
E = os.environ
a = sys.argv[1:]
with open(E["STUB_CALLS"], "a") as f:
    f.write(json.dumps(a) + "\n")
d, kid = E.get("API_PRIVATE_KEYS_DIR", ""), E.get("KEY_ID", "")
if not (kid and E.get("ISSUER_ID") and os.path.isfile(os.path.join(d, "AuthKey_%s.p8" % kid))):
    sys.exit("asc_signing: no App Store Connect key")
if a[:1] == ["cleanup"] and len(a) <= 2:
    sys.exit(1 if E.get("STUB_CLEANUP_FAIL") else 0)
if a[:1] == ["create"] and len(a) == 5:
    csr, bundle, name, out = a[1:]
    if subprocess.run(["openssl", "req", "-in", csr, "-noout", "-verify"], capture_output=True).returncode:
        sys.exit("asc_signing: POST /v1/certificates: 409 (not a CSR)")
    src = E["STUB_OTHER_CSR"] if E.get("STUB_MISMATCH") else csr
    der = subprocess.run(["openssl", "x509", "-req", "-in", src, "-CA", E["STUB_CA"] + ".pem", "-CAkey", E["STUB_CA"] + ".key",
                          "-days", "365", "-outform", "der"], capture_output=True, check=True).stdout
    open(os.path.join(out, "cert.cer"), "wb").write(der)
    print("SIGNING_CERTIFICATE_ID=CERT-B", flush=True)
    open(os.path.join(out, "profile.mobileprovision"), "wb").write(b"STUBCMS")
    print("SIGNING_PROFILE_ID=PROF-B", flush=True)
    sys.exit(0)
sys.exit("asc_signing stand-in: refused %s" % a)
''')
        os.chmod(stub, 0o755)

    # -- the runner -------------------------------------------------------------
    def run_job(self, csr_b64, profile_name="sis ci distribution", **extra):
        """Every non-checkout step in order with GitHub's gates. Returns [(name, rc, output)]."""
        job = os.path.join(self.tmp, "job")
        rt = os.path.join(self.tmp, "rt")
        for d in (job, rt):
            shutil.rmtree(d, ignore_errors=True)
            os.makedirs(d)
        os.makedirs(os.path.join(job, "tool"))
        os.symlink(os.path.join(self.bin, "asc_signing.py"), os.path.join(job, "tool", "asc_signing.py"))
        open(self.calls, "w").close()
        genv, summary = os.path.join(self.tmp, "github_env"), os.path.join(self.tmp, "summary")
        open(genv, "w").close()
        open(summary, "w").close()
        secrets = {"APP_STORE_CONNECT_API_KEY": ASC_KEY, "APP_STORE_CONNECT_KEY_ID": "K3YID",
                   "APP_STORE_CONNECT_ISSUER_ID": "issuer"}
        secrets.update({k: v for k, v in extra.items() if k in secrets})
        inputs = {"csr_b64": csr_b64, "profile_name": profile_name}
        job_env = mapping(block(block(wf_lines(), "bootstrap:", 2), "env:", 4), 6)

        def resolve(v):
            m = re.fullmatch(r"\$\{\{ *(secrets|inputs)\.([A-Za-z0-9_-]+) *\}\}", v)
            if not m:
                self.assertNotIn("${{", v, "an expression this test does not model: %s" % v)
                return v
            return (secrets if m.group(1) == "secrets" else inputs)[m.group(2)]

        ok, results = True, []
        for s in steps():
            if s["uses"]:
                continue
            self.assertIn(s["if"], ("", "always()"), "a gate this test does not model: %s" % s["if"])
            if not ok and s["if"] != "always()":
                continue
            run = s["run"]
            self.assertIsNotNone(run, "step %s has no run" % s["name"])
            self.assertNotIn("${{", run, "step '%s' pastes an expression into its script" % s["name"])
            env = {"PATH": os.environ["PATH"], "HOME": self.tmp, "RUNNER_TEMP": rt, "GITHUB_ENV": genv,
                   "GITHUB_STEP_SUMMARY": summary, "STUB_CALLS": self.calls, "STUB_CA": self.ca,
                   "STUB_OTHER_CSR": os.path.join(self.tmp, "other.csr")}
            env.update({k: v for k, v in extra.items() if k.startswith("STUB_")})
            with open(genv) as f:
                env.update(l.split("=", 1) for l in f.read().splitlines() if "=" in l)
            env.update({k: resolve(v) for k, v in job_env.items()})
            env.update({k: resolve(v) for k, v in s["env"].items()})
            script = os.path.join(self.tmp, "step.sh")
            with open(script, "w") as f:
                f.write(run if run.endswith("\n") else run + "\n")
            p = subprocess.run(["bash", "-e", script], cwd=job, env=env, capture_output=True, text=True, timeout=120)
            out = p.stdout + p.stderr
            self.assertNotIn("ASCSECRET", out, "step '%s' printed the App Store Connect key" % s["name"])
            results.append((s["name"], p.returncode, out))
            if p.returncode:
                ok = False
        self.assertFalse(os.path.exists(os.path.join(rt, "asc")), "the App Store Connect key survived the job")
        return results

    def asc_calls(self):
        with open(self.calls) as f:
            return [json.loads(l) for l in f]

    def b64(self, data):
        return base64.b64encode(data).decode()

    # -- shape --------------------------------------------------------------------
    def test_shape(self):
        lines = wf_lines()
        triggers = sorted(mapping(block(lines, "on:", 0), 2))
        self.assertEqual(triggers, ["workflow_dispatch"], "the bootstrap must only be dispatched by hand")
        inputs = block(block(lines, "on:", 0), "inputs:", 4)
        csr = block(inputs, "csr_b64:", 6)
        self.assertIn("required: true", [l.strip() for l in csr], "csr_b64 must be required")
        prof = [l.strip() for l in block(inputs, "profile_name:", 6)]
        self.assertTrue(prof, "no profile_name input")
        self.assertTrue(any(re.fullmatch(r"default: '?sis ci distribution'?", l) for l in prof),
                        "profile_name must default to 'sis ci distribution': %s" % prof)
        self.assertEqual(mapping(block(lines, "permissions:", 0), 2), {"contents": "read"})
        text = "\n".join(lines)
        self.assertNotIn("secrets.IOS_DISTRIBUTION_KEY", text, "the private key must never reach GitHub Actions")
        self.assertEqual(set(re.findall(r"secrets\.([A-Z_]+)", text)), ASC_SECRETS)
        self.assertIsNone(re.search(r"set -x|xtrace|bash -x", text), "tracing would print the key")
        self.assertIn("persist-credentials: false", [l.strip() for l in lines])
        for s in steps():
            if s["run"]:
                self.assertNotIn("${{", s["run"], "step '%s' pastes an expression into its script" % s["name"])
        last = [s for s in steps() if not s["uses"]][-1]
        self.assertEqual(last["if"], "always()", "the key removal must be the last step, if: always()")

    # -- run ----------------------------------------------------------------------
    def test_creates_after_cleanup_and_logs_ids_and_end_date(self):
        res = self.run_job(self.b64(self.csr_pem))
        self.assertEqual([(n, rc) for n, rc, _ in res if rc], [], res)
        calls = self.asc_calls()
        self.assertEqual([c[0] for c in calls], ["cleanup", "create"], "cleanup must sweep before the create")
        self.assertTrue(len(calls[0]) == 1 or float(calls[0][1]) >= 6, "cleanup must spare runs younger than 6 h: %s" % calls[0])
        _, csr_path, bundle, name, out = calls[1]
        self.assertEqual((bundle, name), ("com.esd.sis", "sis ci distribution"))
        self.assertTrue(os.path.isabs(csr_path) and os.path.isabs(out), calls[1])
        log = "".join(o for _, _, o in res)
        for leak in ("CERTIFICATE REQUEST", self.b64(self.csr_pem)[40:100], "BEGIN CERTIFICATE"):
            self.assertNotIn(leak, log, "the bootstrap logged %r" % leak)
        self.assertIn("SIGNING_CERTIFICATE_ID=CERT-B", log)
        self.assertIn("SIGNING_PROFILE_ID=PROF-B", log)
        self.assertRegex(log, r"notAfter=\w{3} +\d+ [\d:]+ \d{4} GMT", "the certificate's end date is not logged")
        for l in log.splitlines():
            # openssl 3.2+ prints its verify status on stdout (3.0, on ubuntu-24.04, on stderr): no data in it.
            self.assertTrue(not l.strip() or re.fullmatch(r"SIGNING_(CERTIFICATE|PROFILE)_ID=\S+", l) or "notAfter=" in l
                            or l == "Certificate request self-signature verify OK",
                            "the bootstrap logged more than ids and the end date: %r" % l)

    def test_certificate_not_for_the_csr_fails(self):
        res = self.run_job(self.b64(self.csr_pem), STUB_MISMATCH="1")
        failed = [n for n, rc, _ in res if rc]
        self.assertTrue(failed, "a certificate for another key passed")
        self.assertIn("create", [c[0] for c in self.asc_calls()])

    def test_not_a_csr_is_refused_before_create(self):
        for bad in (self.b64(b"not a csr"), "%%%not base64", self.b64(self.csr_pem.replace(b"CERTIFICATE REQUEST", b"PUBLIC KEY"))):
            res = self.run_job(bad)
            self.assertTrue([n for n, rc, _ in res if rc], "%r was accepted" % bad[:20])
            self.assertNotIn("create", [c[0] for c in self.asc_calls()], "%r reached create" % bad[:20])

    def test_profile_name_is_data(self):
        name = "sis ci distribution $(touch pwned) `touch pwned2` \"q\" 'q'"
        res = self.run_job(self.b64(self.csr_pem), profile_name=name)
        self.assertEqual([(n, rc) for n, rc, _ in res if rc], [], res)
        self.assertEqual(self.asc_calls()[-1][3], name, "profile_name did not reach create verbatim")
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "job", "pwned")), "profile_name was run as shell")
        self.assertFalse(os.path.exists(os.path.join(self.tmp, "job", "pwned2")), "profile_name was run as shell")

    def test_empty_secret_fails_before_any_call(self):
        for empty in ASC_SECRETS:
            res = self.run_job(self.b64(self.csr_pem), **{empty: ""})
            self.assertTrue([n for n, rc, _ in res if rc], "an empty %s passed" % empty)
            self.assertEqual(self.asc_calls(), [], "App Store Connect was called with %s empty" % empty)


# ---- tool/ios_signing_bootstrap.sh -------------------------------------------------
GH = r'''#!/usr/bin/env python3
import datetime, json, os, stat, subprocess, sys
E = os.environ
a = sys.argv[1:]
d = E["STUB_DIR"]
rec = {"argv": a}
if a[:2] == ["secret", "set"]:
    rec["stdin"] = sys.stdin.read()
if a[:2] == ["workflow", "run"]:
    kd = open(os.path.join(d, "keydir")).read().strip() if os.path.exists(os.path.join(d, "keydir")) else ""
    rec["keydir"] = kd
    if kd and os.path.isdir(kd):
        rec["dir_mode"] = oct(stat.S_IMODE(os.stat(kd).st_mode))
        rec["key_modes"] = {f: oct(stat.S_IMODE(os.stat(os.path.join(kd, f)).st_mode)) for f in os.listdir(kd)
                            if "PRIVATE KEY" in open(os.path.join(kd, f), errors="replace").read()}
    open(os.path.join(d, "dispatched"), "w").close()
with open(os.path.join(d, "gh.jsonl"), "a") as f:
    f.write(json.dumps(rec) + "\n")
if a[:2] == ["auth", "status"]:
    sys.exit(int(E.get("STUB_AUTH_RC", "0")))
if a[:2] == ["workflow", "run"]:
    sys.exit(0)
if a[:2] == ["run", "list"]:
    n = int(open(os.path.join(d, "lists")).read()) + 1 if os.path.exists(os.path.join(d, "lists")) else 1
    open(os.path.join(d, "lists"), "w").write(str(n))
    runs = [{"databaseId": 111, "createdAt": "2000-01-01T00:00:00Z"}]  # an older bootstrap run
    if os.path.exists(os.path.join(d, "dispatched")) and n >= 2 and not E.get("STUB_NEVER"):
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        runs.insert(0, {"databaseId": 777, "createdAt": now})
    jq = a[a.index("--jq") + 1] if "--jq" in a else "."
    sys.stdout.write(subprocess.run(["jq", "-r", jq], input=json.dumps(runs), capture_output=True, text=True, check=True).stdout)
    sys.exit(0)
if a[:2] == ["run", "watch"]:
    sys.exit(int(E.get("STUB_RUN_RC", "0")) if a[2] == "777" else 3)
if a[:2] == ["run", "view"]:
    print("bootstrap\tCreate the certificate and profile\t2026-10-01T00:00:00.0000000Z SIGNING_CERTIFICATE_ID=CERT-B")
    print("bootstrap\tCreate the certificate and profile\t2026-10-01T00:00:00.0000000Z Certificate notAfter=Oct  1 00:00:00 2027 GMT")
    sys.exit(0)
if a[:2] == ["secret", "set"]:
    sys.exit(int(E.get("STUB_SECRET_RC", "0")))
sys.exit("gh stand-in: unexpected %s" % a)
'''
DOCKER = r'''#!/usr/bin/env bash
# docker compose run ... -v HOST:CONTAINER ... SCRIPT: runs SCRIPT here, CONTAINER mapped to HOST.
printf '%s\n' "$*" >> "$STUB_DIR/docker.log"
host= mnt= prev=
for a in "$@"; do
  if [ "$prev" = -v ] || [ "$prev" = --volume ]; then host=${a%%:*}; mnt=${a#*:}; mnt=${mnt%%:*}; fi
  prev=$a
done
printf '%s\n' "$host" > "$STUB_DIR/keydir"
[ -z "${STUB_DOCKER_FAIL:-}" ] || exit 1
script=${*: -1}
sh -c "${script//$mnt/$host}"
'''


class ScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.repo, self.bin, self.stub = (os.path.join(self.tmp, d) for d in ("repo", "bin", "stub"))
        for d in (self.bin, self.stub, os.path.join(self.repo, "tool")):
            os.makedirs(d)
        shutil.copy(SCRIPT, os.path.join(self.repo, "tool"))
        for name, body in (("gh", GH), ("docker", DOCKER), ("sleep", "#!/bin/sh\nexit 0\n")):
            with open(os.path.join(self.bin, name), "w") as f:
                f.write(body)
            os.chmod(os.path.join(self.bin, name), 0o755)

    def run_script(self, *args, **extra):
        env = dict(os.environ, PATH=self.bin + ":" + os.environ["PATH"], STUB_DIR=self.stub, **extra)
        p = subprocess.run(["bash", os.path.join(self.repo, "tool", "ios_signing_bootstrap.sh"), *args], cwd=self.tmp,
                           env=env, capture_output=True, text=True, timeout=120)
        self.gh = []
        if os.path.exists(os.path.join(self.stub, "gh.jsonl")):
            with open(os.path.join(self.stub, "gh.jsonl")) as f:
                self.gh = [json.loads(l) for l in f]
        kd = os.path.join(self.stub, "keydir")
        self.keydir = ""
        if os.path.exists(kd):
            with open(kd) as f:
                self.keydir = f.read().strip()
        return p

    def find(self, *prefix):
        return [c for c in self.gh if c["argv"][:len(prefix)] == list(prefix)]

    def index(self, *prefix):
        return next(i for i, c in enumerate(self.gh) if c["argv"][:len(prefix)] == list(prefix))

    def fields(self, call):
        a = call["argv"]
        return dict(a[i + 1].split("=", 1) for i, x in enumerate(a) if x in ("-f", "--field", "-F", "--raw-field"))

    def assert_key_gone(self, p):
        self.assertTrue(self.keydir, "the key was not generated through docker")
        self.assertFalse(os.path.exists(self.keydir), "the temporary key directory survived")
        out = p.stdout + p.stderr
        self.assertNotIn("PRIVATE KEY", out, "the key was printed")
        for c in self.gh:
            self.assertNotIn("PRIVATE KEY", " ".join(c["argv"]), "the key was passed as an argument: %s" % c["argv"][:3])

    def test_dispatches_csr_waits_then_stores_key(self):
        p = self.run_script("fix/ref", "sis ci distribution 2027")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        runs = self.find("workflow", "run")
        self.assertEqual(len(runs), 1)
        self.assertIn("ios-signing-bootstrap.yml", runs[0]["argv"])
        a = runs[0]["argv"]
        self.assertEqual(a[a.index("--ref") + 1], "fix/ref")
        f = self.fields(runs[0])
        self.assertEqual(sorted(f), ["csr_b64", "profile_name"], "the workflow gets the CSR and the name, nothing else")
        self.assertEqual(f["profile_name"], "sis ci distribution 2027")
        csr = os.path.join(self.tmp, "sent.csr")
        with open(csr, "wb") as fh:
            fh.write(base64.b64decode(f["csr_b64"]))
        sh("openssl", "req", "-in", csr, "-noout", "-verify")
        # The private directory, while the run went: 700, the key 600.
        self.assertEqual(runs[0].get("dir_mode"), "0o700", runs[0])
        self.assertTrue(runs[0].get("key_modes"), "no key in the directory at dispatch")
        self.assertEqual(set(runs[0]["key_modes"].values()), {"0o600"}, runs[0]["key_modes"])
        # That run, not the older one; the secret only after it succeeded.
        self.assertEqual([c["argv"][2] for c in self.find("run", "watch")], ["777"], "waited on the wrong run")
        self.assertIn("--exit-status", self.find("run", "watch")[0]["argv"])
        sets = self.find("secret", "set")
        self.assertEqual(len(sets), 1)
        self.assertLess(self.index("run", "watch"), self.index("secret", "set"), "the key was stored before the run succeeded")
        self.assertEqual(sets[0]["argv"][2], "IOS_DISTRIBUTION_KEY")
        self.assertFalse({"-b", "--body", "-f", "--env-file"} & set(sets[0]["argv"]), "the key must arrive on stdin: %s" % sets[0]["argv"])
        key = os.path.join(self.tmp, "stored.pem")
        with open(key, "w") as fh:
            fh.write(sets[0]["stdin"])
        self.assertEqual(pubkey(key, "key"), pubkey(csr, "csr"), "the stored key is not the CSR's key")
        self.assert_key_gone(p)

    def test_default_profile_name(self):
        p = self.run_script("main")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertEqual(self.fields(self.find("workflow", "run")[0])["profile_name"], "sis ci distribution")

    def test_failures_store_nothing(self):
        for env, ran_workflow in (({"STUB_RUN_RC": "1"}, True), ({"STUB_NEVER": "1"}, True),
                                  ({"STUB_DOCKER_FAIL": "1"}, False), ({"STUB_AUTH_RC": "1"}, False)):
            shutil.rmtree(self.stub)
            os.mkdir(self.stub)
            p = self.run_script("main", **env)
            self.assertNotEqual(p.returncode, 0, "%s: the script succeeded" % env)
            self.assertEqual(self.find("secret", "set"), [], "%s: the key was stored" % env)
            self.assertEqual(bool(self.find("workflow", "run")), ran_workflow, "%s: dispatch %s" % (env, self.gh))
            if "STUB_NEVER" in env:
                self.assertEqual(self.find("run", "watch"), [], "a run that never appeared was watched")
            if "STUB_AUTH_RC" not in env:
                self.assert_key_gone(p)

    def test_failed_secret_store_fails_and_removes_key(self):
        p = self.run_script("main", STUB_SECRET_RC="1")
        self.assertNotEqual(p.returncode, 0, "a failed gh secret set was ignored")
        self.assert_key_gone(p)


if __name__ == "__main__":
    unittest.main(verbosity=1)
