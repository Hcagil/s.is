# Base images are copies in our own registry (made by tool/ensure_base_images.sh, same digests); Docker Hub rate-limits anonymous pulls from CI.
FROM ghcr.io/hcagil/base-docker:29.8.0-cli@sha256:eccaacfeed644c7de222ff047483568cb988dde95476fbaaf10ea2d04921bb66 AS docker

FROM ghcr.io/hcagil/base-node:22.20.0-bookworm-slim@sha256:b21fe589dfbe5cc39365d0544b9be3f1f33f55f3c86c87a76ff65a02f8f5848e

ARG SUPABASE_CLI_VERSION=2.117.0

COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker

RUN npm install --global "supabase@${SUPABASE_CLI_VERSION}" \
    && npm cache clean --force

ENTRYPOINT ["supabase"]
