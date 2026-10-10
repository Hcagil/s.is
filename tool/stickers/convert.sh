#!/usr/bin/env bash
# Rebuilds assets/stickers/*.webp from the PNGs in tool/stickers/noto, and the owner's
# preview page (path in $1, default .private/mockups/starter-stickers/index.html).
# Needs Docker only. Runs as root inside the container (apt needs it) and hands
# the output files back to the calling user.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
page="${1:-.private/mockups/starter-stickers/index.html}"
docker run --rm -v "$root":/work -w /work -e UID_GID="$(id -u):$(id -g)" -e PAGE="$page" python:3-slim sh -c '
  pip install --quiet pillow &&
  python tool/stickers/convert.py tool/stickers/noto assets/stickers "$PAGE" &&
  chown -R "$UID_GID" assets/stickers "$(dirname "$PAGE")"'
