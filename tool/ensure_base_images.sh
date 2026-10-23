#!/usr/bin/env bash
# Docker Hub rate-limits anonymous pulls from CI, so the base images live in our own
# registry (ghcr.io/<owner>/). Copies each one there by digest unless it is already there.
# Needs `docker login ghcr.io` with write access; the digests must match docker/*Dockerfile and ci.yml.
# The supabase/* entries are what the Supabase CLI (docker/Supabase.Dockerfile) pulls for `start` and `test db`; the tags must match its image list.
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
supabase/postgres 17.6.1.167 sha256:6942962433a569e87f228b4d4ab7e11db5deca64e43babb3a038443ad6c4f1bb public.ecr.aws/supabase/postgres
supabase/kong 2.8.1 sha256:1b53405d8680a09d6f44494b7990bf7da2ea43f84a258c59717d4539abf09f6d public.ecr.aws/supabase/kong
supabase/postgrest v16.2 sha256:85258123312dc496ad4c2ed832154a65e9746f84df0d6d09b44229ff9230c08e public.ecr.aws/supabase/postgrest
supabase/gotrue v2.196.0 sha256:c0c25187a6b835e65a6f6e6c6b39d090e832d40e6de5186f2c038e0411944232 public.ecr.aws/supabase/gotrue
supabase/realtime v2.130.0 sha256:002193c9ff840a4946918641901bb6aa9e2036dc9ff7590e2b11e91d1e06bf86 public.ecr.aws/supabase/realtime
supabase/storage-api v1.72.1 sha256:105a2584129c9600aebed6f5ac49ca4371c92b996ecd1af7179750333e9e2120 public.ecr.aws/supabase/storage-api
supabase/pg_prove 3.36 sha256:eda7c5e68719e9c8287e78c017118407b48df904a51c935f5ab6098b8c0bc6bc public.ecr.aws/supabase/pg_prove
EOF
