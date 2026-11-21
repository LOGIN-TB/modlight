# Podlight server. Build from the repository root (it needs spec/):
#   docker build -f server/Dockerfile -t podlight-server .
FROM node:24-bookworm-slim AS deps
WORKDIR /app/server
COPY server/package.json server/package-lock.json ./
# better-sqlite3 ships prebuilt binaries for linux x64/arm64; only production dependencies.
RUN npm ci --omit=dev

FROM node:24-bookworm-slim
WORKDIR /app
ENV NODE_ENV=production DATA_DIR=/data PORT=8080 SPEC_DIR=/app/spec
# tini forwards SIGTERM so `docker stop` closes the server instead of waiting for the kill.
RUN apt-get update \
 && apt-get install -y --no-install-recommends tini \
 && rm -rf /var/lib/apt/lists/*
COPY --from=deps /app/server/node_modules ./server/node_modules
COPY server/package.json ./server/
COPY server/src ./server/src
# The shared rules: GPU table, regions, the pod's start script and watchdog.
COPY spec/data ./spec/data
COPY spec/pod ./spec/pod
RUN mkdir -p /data && chown -R node:node /data
USER node
VOLUME ["/data"]
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||8080)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "--disable-warning=ExperimentalWarning", "server/src/index.ts"]
