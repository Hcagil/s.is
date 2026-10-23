# Base images come from the AWS ECR Public mirror of Docker Official Images (same digests); Docker Hub rate-limits anonymous pulls from CI.
FROM public.ecr.aws/docker/library/docker:29.8.0-cli AS docker

FROM public.ecr.aws/docker/library/node:22.20.0-bookworm-slim

ARG SUPABASE_CLI_VERSION=2.117.0

COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker

RUN npm install --global "supabase@${SUPABASE_CLI_VERSION}" \
    && npm cache clean --force

ENTRYPOINT ["supabase"]
