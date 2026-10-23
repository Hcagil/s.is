#!/usr/bin/env bash
# Docker Hub rate-limits anonymous pulls from CI, so the base images live in our own
# registry (ghcr.io/<owner>/). Copies each one there by digest unless it is already there.
# Needs `docker login ghcr.io` with write access; the digests must match docker/*Dockerfile and ci.yml.
set -euo pipefail
dest="ghcr.io/${GITHUB_REPOSITORY_OWNER:?}"
dest="${dest,,}"
while read -r name tag digest source; do
  if docker buildx imagetools inspect "$dest/$name@$digest" >/dev/null 2>&1; then
    echo "present: $name:$tag"
    continue
  fi
  docker buildx imagetools create --tag "$dest/$name:$tag" "$source@$digest"
  got=$(docker buildx imagetools inspect "$dest/$name:$tag" --format '{{json .Manifest.Digest}}' | tr -d '"')
  if [ "$got" != "$digest" ]; then
    echo "digest mismatch for $name:$tag: $got" >&2
    exit 1
  fi
  echo "copied: $name:$tag"
done <<'EOF'
base-ubuntu 24.04 sha256:68ee22004a9109b44973313b02ff7b1de250f1de0f5ecb628d73f579aaff33ac docker.io/library/ubuntu
base-node 22.20.0-bookworm-slim sha256:b21fe589dfbe5cc39365d0544b9be3f1f33f55f3c86c87a76ff65a02f8f5848e docker.io/library/node
base-docker 29.8.0-cli sha256:eccaacfeed644c7de222ff047483568cb988dde95476fbaaf10ea2d04921bb66 docker.io/library/docker
base-deno 2.9.7 sha256:fa335acdf6b72106eda2cb6a8cb5f4187e7630e357467489db4b2e7352d5e432 ghcr.io/denoland/deno
EOF
