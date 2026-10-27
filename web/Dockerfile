# syntax=docker/dockerfile:1
# NoteIt web: one image, one /data volume. Build from the web/ directory:
#   docker build -t noteit-web .
# Releases publish it as ghcr.io/rutbergphilip/noteit-web (.github/workflows/web-release.yml, docs/self-hosting.md).
#
# Multi-arch without emulating the build: the build stage runs on the build machine's platform, because the
# client and the bundled server are plain JavaScript and identical for every architecture. The only native
# module, the argon2 binding, comes from a small stage that runs on the target platform.

ARG NODE_VERSION=22
ARG ARGON2_VERSION=2.2.1

FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-alpine AS build
ARG ARGON2_VERSION
WORKDIR /src
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
# The pnpm version named in package.json's packageManager.
# hadolint ignore=DL3016
RUN npm install -g --no-audit --no-fund "$(node -p 'require("./package.json").packageManager')"
COPY packages/core/package.json packages/core/
COPY packages/doc/package.json packages/doc/
COPY apps/web/package.json apps/web/
# Install once without scripts (nuxt prepare needs the sources), then copy sources and build.
RUN pnpm install --frozen-lockfile --ignore-scripts
COPY packages packages
COPY apps/web apps/web
ARG NOTEIT_VERSION=dev
# A fixed build id makes the client reproducible (the signed release manifest covers it).
ENV NOTEIT_BUILD_ID=noteit-${NOTEIT_VERSION}
# Nitro traces only the build platform's argon2 binding into .output; drop it, the runtime stage adds the target's.
RUN pnpm rebuild esbuild \
 && pnpm --filter @noteit/web exec nuxt prepare \
 && pnpm --filter @noteit/web build \
 && out=apps/web/.output/server/node_modules/@node-rs \
 && test "$(node -p "require('./$out/argon2/package.json').version")" = "$ARGON2_VERSION" \
 && rm -rf "$out"/argon2-*

FROM node:${NODE_VERSION}-alpine AS argon2
ARG ARGON2_VERSION
WORKDIR /argon2
RUN npm install --no-save --no-package-lock --omit=dev --no-audit --no-fund "@node-rs/argon2@${ARGON2_VERSION}" \
 && node -e "require('@node-rs/argon2').hashSync('check')"

FROM node:${NODE_VERSION}-alpine
ARG NOTEIT_VERSION=dev
ARG NOTEIT_COMMIT=dev
LABEL org.opencontainers.image.source="https://github.com/rutbergphilip/noteit" \
      org.opencontainers.image.url="https://github.com/rutbergphilip/noteit/blob/main/docs/self-hosting.md" \
      org.opencontainers.image.documentation="https://github.com/rutbergphilip/noteit/blob/main/docs/self-hosting.md" \
      org.opencontainers.image.title="NoteIt web" \
      org.opencontainers.image.description="Self-hosted, end-to-end encrypted NoteIt web app and sync server" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.version="${NOTEIT_VERSION}" \
      org.opencontainers.image.revision="${NOTEIT_COMMIT}"
# tini forwards SIGTERM to node and reaps zombies (node isn't a good PID 1).
# hadolint ignore=DL3018
RUN apk add --no-cache tini
ENV NODE_ENV=production \
    NOTEIT_DATA_DIR=/data \
    NOTEIT_VERSION=${NOTEIT_VERSION} \
    NOTEIT_COMMIT=${NOTEIT_COMMIT} \
    PORT=3000 \
    HOST=0.0.0.0
WORKDIR /app
# The app stays owned by root and read-only to the server; only /data is writable.
COPY --from=build /src/apps/web/.output ./.output
COPY --from=argon2 /argon2/node_modules/@node-rs/ ./.output/server/node_modules/@node-rs/
RUN mkdir -p /data && chown 1000:1000 /data && chmod 700 /data
# uid 1000 is the image's `node` user.
USER 1000:1000
VOLUME /data
EXPOSE 3000
# Liveness only: /api/health (readiness) answers 503 while the store is unreachable, which a restart can't fix.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["wget", "-q", "-O", "/dev/null", "http://127.0.0.1:3000/api/health/live"]
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", ".output/server/index.mjs"]
