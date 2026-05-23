#!/bin/sh
# Marveen container entrypoint.
#
# Runs every container start. Idempotent: skips work that's already done
# (plugin installed, skills seeded, model pulled). Exits non-zero on fatal
# misconfiguration so the container restart loop surfaces the problem.

set -e

log() { printf '[entrypoint] %s\n' "$*"; }

# 1. CLAUDE_CODE_OAUTH_TOKEN is required — agents shell out to `claude` and
#    fail with an opaque tmux-internal error if no token is present. Surface
#    it loudly here instead.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    cat >&2 <<'EOF'
FATAL: CLAUDE_CODE_OAUTH_TOKEN environment variable is required.

Generate one on a machine with a browser:
  $ claude setup-token

Then set it in .env (local) or Xcloud's env-var panel:
  CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-...
EOF
    exit 1
fi

# 2. Wait for Ollama to be reachable. depends_on/condition handles it in
#    docker-compose, but a manual `docker run` of just the marveen image
#    benefits from a soft wait too. 60s budget; after that, start anyway so
#    the dashboard comes up — embeddings will fail but the UI still works.
OLLAMA_URL="${OLLAMA_URL:-http://ollama:11434}"
log "Waiting for Ollama at $OLLAMA_URL (max 60s)..."
ollama_ready=0
i=0
while [ $i -lt 30 ]; do
    if curl -sf "${OLLAMA_URL}/api/tags" >/dev/null 2>&1; then
        ollama_ready=1
        break
    fi
    sleep 2
    i=$((i + 1))
done
if [ $ollama_ready -eq 1 ]; then
    log "Ollama ready."
else
    log "WARN: Ollama not reachable after 60s; continuing — embeddings will fail."
fi

# 3. Ensure runtime directories exist (volumes mount empty on first start).
mkdir -p /root/.claude /app/store /app/agents /app/workspace /app/reports

# 4. Install the channel plugin idempotently. Skipped if already installed.
CHANNEL_PROVIDER="${CHANNEL_PROVIDER:-telegram}"
case "$CHANNEL_PROVIDER" in
    slack)
        PLUGIN_ID="slack@jeremylongshore/claude-code-slack-channel"
        MARKETPLACE="jeremylongshore/claude-code-slack-channel"
        ;;
    telegram|*)
        PLUGIN_ID="telegram@claude-plugins-official"
        MARKETPLACE="anthropics/claude-plugins-official"
        ;;
esac

if claude plugin list 2>/dev/null | grep -q "$PLUGIN_ID"; then
    log "Plugin already installed: $PLUGIN_ID"
else
    log "Installing Claude Code plugin: $PLUGIN_ID"
    claude plugin marketplace add "$MARKETPLACE" 2>/dev/null || true
    if claude plugin install "$PLUGIN_ID" 2>/dev/null; then
        log "Plugin installed."
    else
        log "WARN: plugin install failed — channels won't work until installed manually."
    fi
fi

# 5. Seed fleet-level skills into ~/.claude/skills/. Idempotent: existing
#    skill directories are preserved (the operator may have edited them).
if [ -d /app/seed-skills ]; then
    for d in /app/seed-skills/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        if [ ! -e "/root/.claude/skills/$name" ]; then
            mkdir -p /root/.claude/skills
            cp -r "$d" "/root/.claude/skills/"
            log "Seeded skill: $name"
        fi
    done
fi

# 6. Seed scheduled tasks into ~/.claude/scheduled-tasks/. Idempotent.
if [ -d /app/seed-scheduled-tasks ]; then
    for d in /app/seed-scheduled-tasks/*/; do
        [ -d "$d" ] || continue
        name=$(basename "$d")
        if [ ! -e "/root/.claude/scheduled-tasks/$name" ]; then
            mkdir -p /root/.claude/scheduled-tasks
            cp -r "$d" "/root/.claude/scheduled-tasks/"
            log "Seeded scheduled task: $name"
        fi
    done
fi

log "Bootstrap complete. Starting: $*"
exec "$@"
