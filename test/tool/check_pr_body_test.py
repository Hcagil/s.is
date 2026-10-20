#!/usr/bin/env python3
"""tool/check_pr_body.py: the "What's new" lines of a PR body (env PR_BODY).

Accepts both lines filled, both empty, the older TR label and CRLF bodies;
refuses inline EN "..." TR "..." labels, and one language without the other.
"""

import unittest
import subprocess
import importlib.util
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

spec = importlib.util.spec_from_file_location(
    "check_pr_body", REPO / "tool/check_pr_body.py"
)
check_pr_body = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_pr_body)


class TestCheckPRBody(unittest.TestCase):
    # Accept cases
    def test_accept_a(self):
        body = (
            "Summary\n\n"
            "For users: Photos crop faster.\n"
            "For users (TR): Fotoğraflar daha hızlı.\n"
        )
        self.assertIsNone(check_pr_body.check(body))

    def test_accept_b(self):
        # No For users lines at all
        body = "Some unrelated content\n"
        self.assertIsNone(check_pr_body.check(body))

        # Empty For users lines
        body = "For users:\nFor users (TR):\n"
        self.assertIsNone(check_pr_body.check(body))

        # Completely empty body
        body = ""
        self.assertIsNone(check_pr_body.check(body))

    def test_accept_c(self):
        body = (
            "For users: Photos crop faster.\n"
            "Kullanıcılar için: Fotoğraflar daha hızlı.\n"
        )
        self.assertIsNone(check_pr_body.check(body))

    def test_accept_d(self):
        body = "For users: A\r\nFor users (TR): B\r\n"
        self.assertIsNone(check_pr_body.check(body))

    # Refuse cases
    def test_refuse_e(self):
        # Inline both labels on one line
        body = (
            'For users: EN "Photos crop faster." TR "Fotoğraflar daha hızlı."\n'
            "For users (TR): x\n"
        )
        err = check_pr_body.check(body)
        self.assertTrue(isinstance(err, str) and err)

        # Inline labels on TR line
        body = (
            'For users: x\n'
            'For users (TR): EN "a" TR "b"\n'
        )
        err = check_pr_body.check(body)
        self.assertTrue(isinstance(err, str) and err)

    def test_refuse_f(self):
        # EN filled, TR missing
        body = "For users: Photos crop faster.\n"
        err = check_pr_body.check(body)
        self.assertTrue(isinstance(err, str) and err)

        # EN filled, TR empty
        body = "For users: A\nFor users (TR):   \n"
        err = check_pr_body.check(body)
        self.assertTrue(isinstance(err, str) and err)

    def test_refuse_g(self):
        # TR filled, EN missing
        body = "For users (TR): B\n"
        err = check_pr_body.check(body)
        self.assertTrue(isinstance(err, str) and err)

        # TR filled, EN empty
        body = "For users:  \nFor users (TR): B\n"
        err = check_pr_body.check(body)
        self.assertTrue(isinstance(err, str) and err)

        # Only older label
        body = "Kullanıcılar için: B\n"
        err = check_pr_body.check(body)
        self.assertTrue(isinstance(err, str) and err)

    def test_refuse_h(self):
        body = "For users: A\r\nFor users (TR): \r\n"
        err = check_pr_body.check(body)
        self.assertTrue(isinstance(err, str) and err)


class TestScriptExecution(unittest.TestCase):
    def run_script(self, body=None):
        env = os.environ.copy()
        if body is not None:
            env["PR_BODY"] = body
        else:
            env.pop("PR_BODY", None)
        return subprocess.run(
            [sys.executable, str(REPO / "tool/check_pr_body.py")],
            env=env,
            capture_output=True,
            text=True,
        )

    def test_script_accept(self):
        body = "For users: A\nFor users (TR): B\n"
        result = self.run_script(body)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_script_refuse(self):
        body = "For users: A\nFor users (TR):   \n"
        result = self.run_script(body)
        self.assertEqual(result.returncode, 1)
        self.assertTrue(result.stdout or result.stderr)

    def test_script_no_body(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
