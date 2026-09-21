FROM docker:29.8.0-cli AS docker

FROM node:22.20.0-bookworm-slim

ARG SUPABASE_CLI_VERSION=2.117.0

COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker

RUN npm install --global "supabase@${SUPABASE_CLI_VERSION}" \
    && npm cache clean --force

ENTRYPOINT ["supabase"]
