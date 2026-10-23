# NoteIt web: one image, one /data volume. Build from the web/ directory:
#   docker build -t noteit-web .
FROM node:22-alpine AS build
WORKDIR /src
RUN corepack enable
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
COPY packages/core/package.json packages/core/
COPY packages/doc/package.json packages/doc/
COPY apps/web/package.json apps/web/
# Install once without scripts (nuxt prepare needs the sources), then copy sources and build.
RUN pnpm install --frozen-lockfile --ignore-scripts
COPY packages packages
COPY apps/web apps/web
RUN pnpm rebuild @node-rs/argon2 esbuild \
 && pnpm --filter @noteit/web exec nuxt prepare \
 && pnpm --filter @noteit/web build

FROM node:22-alpine
ENV NODE_ENV=production \
    NOTEIT_DATA_DIR=/data \
    PORT=3000 \
    HOST=0.0.0.0
WORKDIR /app
COPY --from=build /src/apps/web/.output ./.output
RUN mkdir -p /data && chown node:node /data
USER node
VOLUME /data
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/api/health/live >/dev/null || exit 1
CMD ["node", ".output/server/index.mjs"]
