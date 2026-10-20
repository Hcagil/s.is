#!/usr/bin/env python3
# Checks the "What's new" lines of a PR body (env PR_BODY) the way release.yml reads them.
import os
import re
import sys


def check(body):
    en, tr = [], []
    for line in body.replace('\r', '').splitlines():
        if line.startswith('For users:'):
            en.append(line[len('For users:'):].strip())
        elif line.startswith('For users (TR):'):
            tr.append(line[len('For users (TR):'):].strip())
        elif line.startswith('Kullanıcılar için:'):
            tr.append(line[len('Kullanıcılar için:'):].strip())
    en = [v for v in en if v]
    tr = [v for v in tr if v]
    if any(re.search(r'\b(EN|TR)\b\s*[:=]?\s*["“]', v) for v in en + tr):
        return 'put English on "For users:" and Turkish on "For users (TR):", one language per line'
    if en and not tr:
        return '"For users (TR):" is empty but "For users:" is not'
    if tr and not en:
        return '"For users:" is empty but the Turkish line is not'
    return None


if __name__ == '__main__':
    err = check(os.environ.get('PR_BODY', ''))
    if err:
        print(err, file=sys.stderr)
        sys.exit(1)
