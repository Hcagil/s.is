#!/usr/bin/env python3
"""The Vault names the database reads equal the names release.yml writes.

A database function reads its URL and shared secret from the Vault by name;
release.yml creates those secrets. If the two sides use different names, the
function finds nothing and quietly makes no call, and a pgTAP fixture that
seeds the database's own names hides it. So this check compares the two sides
as written:
- read: every `vault.decrypted_secrets ... where name = '<n>'` or `where name in ('<n>', ..)` inside the
  latest definition of each function still alive after all migrations (in
  file order: `create [or replace] function`, `alter function .. rename to`,
  `drop function`);
- written: every `vault.create_secret(<value>, '<n>')` in release.yml.
- created: every `vault.create_secret(..., '<n>')` in a migration file.
The two sets must be equal: a name read but never written fails closed in
production; a name written but never read is a leftover or a typo.
"""
import os, pathlib, re, tempfile, unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
MIGRATIONS = pathlib.Path(os.environ.get("MIGRATIONS_DIR", ROOT / "supabase/migrations"))
WF = pathlib.Path(os.environ.get("RELEASE_YML", ROOT / ".github/workflows/release.yml"))

FN = r"([A-Za-z_][\w]*\.[A-Za-z_]\w*|[A-Za-z_]\w*)"
EVENT = re.compile(
    rf"create\s+(?:or\s+replace\s+)?function\s+{FN}"
    rf"|alter\s+function\s+{FN}\s*\([^)]*\)\s*rename\s+to\s+(\w+)"
    rf"|drop\s+function\s+(?:if\s+exists\s+)?{FN}",
    re.I,
)
READ = re.compile(r"vault\.decrypted_secrets\s+where\s+name\s*(?:=\s*('\w+')|in\s*\(([^)]*)\))", re.I)
NAME = re.compile(r"'(\w+)'")
WRITE = re.compile(r"vault\.create_secret\([^;]*?,\s*'(\w+)'\s*\)")

def names_in(text):
    """Every name a `where name = 'x'` or `where name in ('x', 'y')` reads."""
    return {n for m in READ.finditer(text) for n in NAME.findall(m.group(1) or m.group(2))}

def read_names(mig_dir):
    """Vault names read by the functions alive after every migration."""
    live = {}
    for f in sorted(pathlib.Path(mig_dir).glob("*.sql")):
        text = f.read_text()
        events = list(EVENT.finditer(text))
        for i, m in enumerate(events):
            created, old, new, dropped = m.group(1), m.group(2), m.group(3), m.group(4)
            if created:
                # shortcut: a function's text runs to the next create/alter/drop; fine while vault reads sit in function bodies
                end = events[i + 1].start() if i + 1 < len(events) else len(text)
                live[created.lower()] = names_in(text[m.end():end])
            elif old:
                schema = old.rsplit(".", 1)[0] + "." if "." in old else ""
                live[(schema + new).lower()] = live.pop(old.lower(), set())
            else:
                live.pop(dropped.lower(), None)
    return set().union(*live.values()) if live else set()

def written_names(wf):
    return set(WRITE.findall(pathlib.Path(wf).read_text()))

def created_names(mig_dir):
    """Names created by `vault.create_secret(..., '<n>')` in migration files."""
    names = set()
    for f in sorted(pathlib.Path(mig_dir).glob("*.sql")):
        text = f.read_text()
        idx = 0
        while True:
            m = re.search(r"vault\.create_secret\s*\(", text[idx:], re.I)
            if not m:
                break
            start = idx + m.end()
            depth = 1
            i = start
            while i < len(text) and depth:
                if text[i] == '(':
                    depth += 1
                elif text[i] == ')':
                    depth -= 1
                i += 1
            arg_text = text[start:i-1]
            parts = []
            depth = 0
            part_start = 0
            for j, ch in enumerate(arg_text):
                if ch == '(':
                    depth += 1
                elif ch == ')':
                    depth -= 1
                elif ch == ',' and depth == 0:
                    parts.append(arg_text[part_start:j].strip())
                    part_start = j + 1
            parts.append(arg_text[part_start:].strip())
            if parts:
                last = parts[-1]
                mname = NAME.fullmatch(last)
                if mname:
                    names.add(mname.group(1))
            idx = i
    return names

class VaultNamesTest(unittest.TestCase):
    def test_the_database_reads_exactly_the_names_release_writes(self):
        read, written = read_names(MIGRATIONS), written_names(WF) | created_names(MIGRATIONS)
        self.assertTrue(read, "no Vault read found: the pattern no longer matches the migrations")
        self.assertEqual(read, written,
                         f"read but never written: {sorted(read - written)}; written but never read: {sorted(written - read)}")

    def test_the_checker_follows_renames_and_replacements(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d)
            (p / "1_old.sql").write_text(
                "create or replace function app_private.old_dispatch() returns trigger as $$ begin\n"
                "  select 1 from vault.decrypted_secrets where name = 'old_url'; end $$;\n"
                "create function app_private.gone() returns void as $$ select 1 from vault.decrypted_secrets\n"
                "   where name = 'gone_url' $$;\n")
            (p / "2_new.sql").write_text(
                "alter function app_private.old_dispatch() rename to new_dispatch;\n"
                "drop function app_private.gone();\n")
            self.assertEqual(read_names(p), {"old_url"}, "a rename keeps the body's reads; a drop removes them")
            (p / "3_replace.sql").write_text(
                "create or replace function app_private.new_dispatch() returns trigger as $$\n"
                "  select 1 from vault.decrypted_secrets where name = 'job_url'; $$;\n")
            self.assertEqual(read_names(p), {"job_url"}, "a replacement drops the old reads")
            wf = p / "release.yml"
            wf.write_text("run: supabase db query --linked \"select vault.create_secret('$S', 'sales_url') is not null\"\n")
            self.assertNotEqual(read_names(p), written_names(wf), "a name mismatch is seen")

    def test_the_checker_reads_in_lists(self):
        self.assertEqual(
            names_in("select 1 from vault.decrypted_secrets where name in ('x','y')"),
            {"x", "y"},
        )
        self.assertEqual(
            names_in("select 1 from vault.decrypted_secrets\n  where name in (\n 'a',\n 'b' )"),
            {"a", "b"},
        )
        self.assertEqual(
            names_in("... vault.decrypted_secrets where name in ('only')"),
            {"only"},
        )
        self.assertEqual(
            names_in("... vault.decrypted_secrets where name = 'eq'"),
            {"eq"},
        )
        self.assertEqual(
            names_in("select 1"),
            set(),
        )

    def test_the_checker_counts_names_a_migration_creates(self):
        with tempfile.TemporaryDirectory() as d:
            p = pathlib.Path(d)
            (p / "1.sql").write_text(
                "select vault.create_secret(encode(gen_random_bytes(32),'hex'), 'log_key');\n"
                "create function app_private.f() returns void as $$ select 1 from vault.decrypted_secrets where name in ('log_key') $$;\n"
            )
            self.assertEqual(created_names(p), {"log_key"})
            self.assertEqual(read_names(p), {"log_key"})
            (p / "2.sql").write_text(
                "select vault.create_secret('x', 'other');\n"
            )
            self.assertEqual(created_names(p), {"log_key", "other"})
            self.assertEqual(read_names(p), {"log_key"})

if __name__ == "__main__":
    unittest.main()
