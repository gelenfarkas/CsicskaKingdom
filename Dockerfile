# syntax=docker/dockerfile:1.7

# ============================================================================
# Builder: compile TypeScript, install native modules, prune dev deps.
# ============================================================================
FROM node:20-bookworm-slim AS builder

# better-sqlite3 builds from source against node-gyp.
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 make g++ \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build && npm prune --omit=dev

# ============================================================================
# Runtime: minimal image with the binaries marveen shells out to.
# ============================================================================
FROM node:20-bookworm-slim AS runtime

# Why each apt package:
#   tmux           — agent runtime: every agent is a tmux session
#                    (src/web/agent-process.ts spawns sessions via `tmux new-session`)
#   lsof, procps   — process-lock probes lsof -ti and /bin/ps (src/index.ts)
#   ca-certificates — outbound HTTPS to Anthropic / Telegram / Slack
#   git            — used by skill-factory and some seed flows
#   curl, jq       — generic helpers + entrypoint health probes
#   tini           — PID 1 signal handling (forwards SIGTERM to node cleanly)
RUN apt-get update && apt-get install -y --no-install-recommends \
    tmux lsof procps ca-certificates git curl jq tini \
 && rm -rf /var/lib/apt/lists/*

# Claude Code CLI: marveen shells out to `claude` via `resolveFromPath('claude')`.
RUN npm install -g @anthropic-ai/claude-code

WORKDIR /app

# Built application + pruned production deps from the builder stage.
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY package.json package-lock.json ./

# Static assets and seed/template data baked into the image (read-only at runtime).
COPY web ./web
COPY seed-config ./seed-config
COPY seed-skills ./seed-skills
COPY seed-scheduled-tasks ./seed-scheduled-tasks
COPY templates ./templates
COPY scheduled-tasks ./scheduled-tasks
COPY skills ./skills
COPY scripts ./scripts
COPY mcp-catalog.json ./

# Entrypoint: waits for Ollama, seeds plugins/skills idempotently, then exec's CMD.
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Persistent state directories — mounted as named volumes from docker-compose.
RUN mkdir -p /app/store /app/agents /app/workspace /app/reports /root/.claude

ENV NODE_ENV=production \
    MARVEEN_ENV=linux-server \
    WEB_HOST=0.0.0.0 \
    WEB_PORT=3420 \
    HOME=/root

EXPOSE 3420

ENTRYPOINT ["tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["node", "dist/index.js"]
