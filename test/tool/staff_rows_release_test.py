#!/usr/bin/env python3
"""release.yml's staff rows steps, lifted out of the file and run as written.

Contract (the staff chat rows live only in the STAFF_ROWS_JSON secret):
- "Check the staff rows secret" runs before anything is deployed or pushed; an
  empty, malformed or empty-list secret fails it with one generic error line,
  never the secret's text.
- "Load the staff rows" is the step right after "Apply database migrations";
  neither step may continue on error; the secret reaches both only through env.
- The load passes the JSON as base64 (masked), so quotes or shell text in it
  are never run; a failing CLI fails the step with one generic error and none
  of the CLI's output (which would quote the query).
- With STAFF_ROWS_TEST_PSQL set (a psql command for the local stack), the
  exact query the step builds runs against the real staff_load, inside a
  rolled-back transaction.
"""
import base64, json, os, pathlib, re, subprocess, tempfile, unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
WF = pathlib.Path(os.environ.get("RELEASE_YML", ROOT / ".github/workflows/release.yml"))
ROWS = {
    "chats": [{"key": "staff_b", "title_en": "Staff B", "title_tr": "Ekip B 'ş' $(touch pwned)", "sort": 2}],
    "commands": [{"chat_key": "staff_b", "word": "/sales", "handler": "sales_total",
                  "help_en": "it's `x` $HOME", "help_tr": "toplam", "sort": 1}],
}


def parse_steps(text):
    """The steps of each job, read by indentation (no PyYAML: the CI runner is not known to have it).
    A step is a `      - ` item; keys at +2; env children at +4; run blocks are dedented."""
    jobs, steps, cur, key = [], None, None, None
    lines = text.splitlines()
    k = 0
    while k < len(lines):
        line = lines[k]
        if re.match(r"^  [A-Za-z0-9_-]+:\s*$", line):
            steps = []
            jobs.append(steps)
        elif steps is not None and line.startswith("      - "):
            cur = {}
            steps.append(cur)
            line = "        " + line[8:]
        if cur is not None and steps is not None:
            m = re.match(r"^        ([A-Za-z-]+):\s*(.*)$", line)
            if m:
                key, val = m.groups()
                if key == "run" and val.startswith("|"):
                    body = []
                    while k + 1 < len(lines) and (not lines[k + 1].strip() or lines[k + 1].startswith("          ")):
                        k += 1
                        body.append(lines[k][10:])
                    cur["run"] = "\n".join(body).rstrip("\n") + "\n"
                elif key == "env" and not val:
                    cur["env"] = {}
                else:
                    cur[key] = val
            else:
                m = re.match(r"^          ([A-Z_][A-Z0-9_]*):\s*(.*)$", line)
                if m and key == "env":
                    cur["env"][m.group(1)] = m.group(2)
        k += 1
    return jobs


def steps():
    for job in parse_steps(WF.read_text()):
        if "Load the staff rows" in [s.get("name") for s in job]:
            return job
    raise AssertionError("no job has a 'Load the staff rows' step")


def step(name):
    return next(s for s in steps() if s.get("name") == name)


class StaffRowsReleaseTest(unittest.TestCase):
    def run_step(self, name, rows, cli_rc=0):
        d = pathlib.Path(tempfile.mkdtemp())
        (d / "bin").mkdir()
        # The stand-in CLI records its argv, prints the query to stderr like a failing real one, and exits cli_rc.
        stub = d / "bin/supabase"
        stub.write_text(r"""#!/usr/bin/env bash
printf '%s\n' "$*" >> "DIR/calls"
echo "ERROR near: $*" >&2
if [ -n "${STAFF_ROWS_TEST_PSQL:-}" ]; then
  printf "begin;\n%s;\nselect count(*) from app_private.staff_commands where word = '/sales';\nselect title_tr from app_private.staff_chats where key = 'staff_b';\nrollback;\n" "$4" \
    | $STAFF_ROWS_TEST_PSQL > "DIR/db" 2>&1 || exit 1
fi
exit RC
""".replace("DIR", str(d)).replace("RC", str(cli_rc)))
        stub.chmod(0o755)
        env = {"PATH": "%s:/usr/bin:/bin" % (d / "bin"), "HOME": str(d), "STAFF_ROWS": rows,
               "SUPABASE_ACCESS_TOKEN": "t", "SUPABASE_PROJECT_REF": "r"}
        if os.environ.get("STAFF_ROWS_TEST_PSQL"):
            env["STAFF_ROWS_TEST_PSQL"] = os.environ["STAFF_ROWS_TEST_PSQL"]
        p = subprocess.run(["bash", "-e", "-c", step(name)["run"]], cwd=d, env=env, capture_output=True, text=True)
        calls = (d / "calls").read_text() if (d / "calls").exists() else ""
        db = (d / "db").read_text() if (d / "db").exists() else ""
        return p, calls, db, d

    def test_order_env_only_and_no_continue_on_error(self):
        names = [s.get("name") for s in steps()]
        check, push, load = (names.index(n) for n in (
            "Check the staff rows secret", "Apply database migrations (schema goes forward before the app)",
            "Load the staff rows"))
        self.assertEqual(load, push + 1, "the load must be the step right after db push")
        self.assertLess(check, push)
        for n in names[:check]:
            self.assertNotRegex(str(n), r"(?i)deploy|push|link", "the secret check must come before %r" % n)
        for n in ("Check the staff rows secret", "Load the staff rows"):
            s = step(n)
            self.assertNotIn("continue-on-error", s, n)
            self.assertEqual(s["env"]["STAFF_ROWS"], "${{ secrets.STAFF_ROWS_JSON }}", n)
            self.assertNotIn("${{", s["run"], "%s: an expression pasted into the script" % n)
        self.assertEqual(len(re.findall(r"secrets\.STAFF_ROWS_JSON", WF.read_text())), 2, "only those two steps see it")

    def test_check_refuses_bad_secrets_with_one_generic_line(self):
        for rows in ("", "not json", "{}", '{"chats":[],"commands":[{"a":1}]}', '{"chats":[{"k":1}]}',
                     '{"chats":[{"k":1}],"commands":[]}', '[1]', '{"chats":"x","commands":"y"}'):
            p, *_ = self.run_step("Check the staff rows secret", rows)
            self.assertNotEqual(p.returncode, 0, rows)
            self.assertEqual(p.stdout + p.stderr, "::error::STAFF_ROWS_JSON is missing or malformed\n", rows)
        p, *_ = self.run_step("Check the staff rows secret", json.dumps(ROWS))
        self.assertEqual((p.returncode, p.stdout + p.stderr), (0, ""))

    def test_load_passes_base64_masked_and_nothing_runs_as_shell(self):
        raw = json.dumps(ROWS, ensure_ascii=False)
        p, calls, _, d = self.run_step("Load the staff rows", raw)
        self.assertEqual(p.returncode, 0, p.stderr)
        b64 = base64.b64encode(raw.encode()).decode()
        self.assertEqual(p.stdout, "::add-mask::%s\n" % b64, "only the mask is printed")
        self.assertEqual(p.stderr, "")
        self.assertEqual(calls.count("\n"), 1, calls)
        self.assertIn("decode('%s','base64')" % b64, calls)
        self.assertNotIn("Ekip", calls, "the JSON text itself never reaches the command line")
        self.assertFalse((d / "pwned").exists(), "the rows were run as shell")

    def test_failing_cli_fails_with_one_generic_line_and_no_query(self):
        p, calls, _, _ = self.run_step("Load the staff rows", json.dumps(ROWS), cli_rc=1)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stderr, "")
        self.assertEqual(p.stdout.splitlines()[1:], ["::error::staff rows load failed"])
        self.assertNotIn("decode(", p.stdout.splitlines()[1])

    @unittest.skipUnless(os.environ.get("STAFF_ROWS_TEST_PSQL"), "needs the local stack (STAFF_ROWS_TEST_PSQL)")
    def test_real_staff_load_reads_the_query_the_step_builds(self):
        p, _, db, _ = self.run_step("Load the staff rows", json.dumps(ROWS, ensure_ascii=False))
        self.assertEqual(p.returncode, 0, db)
        self.assertRegex(db, r"(?m)^ *t$", "staff_load answered: %s" % db)
        self.assertRegex(db, r"(?m)^ *1$", "the command row was written: %s" % db)
        self.assertIn("\n" + ROWS["chats"][0]["title_tr"] + "\n", db, "the title arrived byte for byte")
        self.assertNotIn("ERROR", db)


if __name__ == "__main__":
    unittest.main()
