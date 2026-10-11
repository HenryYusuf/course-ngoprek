# syntax=docker/dockerfile:1
ARG NODE_VERSION=22

# ---------- Build stage ----------
# Astro build compiles the admin UI and inlines the seed file, so the builder
# needs the full dependency tree. Node 22 matches the EmDash minimum (22.16+).
FROM node:${NODE_VERSION}-bookworm-slim AS builder

WORKDIR /app

# astro.config.mjs is evaluated by `astro build`, NOT at server start, so both
# of these must be set here or they get baked in as their defaults:
# - data paths resolve to ./data.db (outside the volume -> lost on redeploy)
# - the public origin is missing, so media ships unoptimized
ARG EMDASH_SITE_URL=https://course.ngoprekonline.com
ENV EMDASH_SITE_URL=${EMDASH_SITE_URL} \
    EMDASH_DATA_DIR=/app/data

# Dependency layer (cached until the lockfile changes)
COPY package.json package-lock.json ./
RUN npm ci

# Source layer (cached until app code or content changes)
COPY . .

RUN npm run build

# ---------- Runtime stage ----------
FROM node:${NODE_VERSION}-bookworm-slim AS runner

# EMDASH_ENCRYPTION_KEY is deliberately absent: EmDash reads it from
# process.env at startup, and secrets never belong in an image layer.
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=4321 \
    EMDASH_SITE_URL=https://course.ngoprekonline.com \
    EMDASH_DATA_DIR=/app/data

WORKDIR /app

COPY --from=builder /app/dist ./dist
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./

# SQLite (data.db + WAL files) and media (uploads) both live here, so one
# persistent volume mounted at /app/data survives redeploys.
RUN mkdir -p /app/data

EXPOSE 4321

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:4321/_emdash/api/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["node", "./dist/server/entry.mjs"]
