#!/usr/bin/env bash
# SSOP Agent Docker Entrypoint
# Reads env vars → generates openclaw config → starts gateway.
# No installs, no patches — everything baked into image.
set -euo pipefail

# --- Required env vars ---
: "${NOSTR_NSEC:?NOSTR_NSEC is required}"
: "${NOSTR_NPUB:?NOSTR_NPUB is required}"
: "${PPQ_API_KEY:?PPQ_API_KEY is required}"
: "${MODEL_ID:=qwen/qwen3-30b-a3b}"
: "${AGENT_NAME:=Agent}"
: "${OWNER_NPUB:=}"
: "${GATEWAY_PORT:=18789}"
: "${DM_POLICY:=pairing}"

WORKSPACE="${AGENT_WORKSPACE:-/root/agent}"
OPENCLAW_DIR="/root/.openclaw"

echo "=== SSOP Agent (Docker) ==="
echo "Agent: $AGENT_NAME"
echo "npub:  $NOSTR_NPUB"
echo "Model: ppq/$MODEL_ID"
echo ""

# --- Ensure workspace exists with defaults ---
mkdir -p "$WORKSPACE/memory" "$WORKSPACE/skills" "$OPENCLAW_DIR"

# Copy defaults only if workspace is empty (first run or fresh mount)
if [ ! -f "$WORKSPACE/SOUL.md" ]; then
    echo "Initializing workspace from defaults..."
    cp -rn /opt/ssop/workspace-defaults/* "$WORKSPACE/" 2>/dev/null || true
    # Stamp identity
    sed -i "s/{{AGENT_NAME}}/$AGENT_NAME/g; s|{{NPUB}}|$NOSTR_NPUB|g" "$WORKSPACE/AGENTS.md" 2>/dev/null || true
    cat > "$WORKSPACE/MEMORY.md" << EOF
# MEMORY.md

Born on $(date -u +%Y-%m-%d) via SSOP (Docker).
Model: $MODEL_ID
Owner: ${OWNER_NPUB:-unknown}
EOF
fi

# --- Generate gateway auth token ---
GW_TOKEN=$(openssl rand -hex 24)

# --- Build allowFrom array ---
ALLOW_FROM="[]"
if [ -n "$OWNER_NPUB" ]; then
    ALLOW_FROM="[\"$OWNER_NPUB\"]"
fi

# --- Write openclaw config ---
cat > "$OPENCLAW_DIR/openclaw.json" << EOFCONFIG
{
  "agents": {
    "defaults": {
      "workspace": "$WORKSPACE",
      "model": {
        "primary": "ppq/$MODEL_ID"
      }
    }
  },
  "models": {
    "mode": "merge",
    "providers": {
      "ppq": {
        "baseUrl": "https://api.ppq.ai/v1",
        "apiKey": "\${PPQ_API_KEY}",
        "api": "openai-completions",
        "models": [
          { "id": "$MODEL_ID", "name": "$MODEL_ID" }
        ]
      }
    }
  },
  "skills": {
    "load": {
      "extraDirs": ["$WORKSPACE/skills"]
    }
  },
  "channels": {
    "nostr": {
      "enabled": true,
      "privateKey": "\${NOSTR_PRIVATE_KEY}",
      "relays": [
        "wss://relay.damus.io",
        "wss://relay.primal.net",
        "wss://nos.lol"
      ],
      "dmPolicy": "$DM_POLICY",
      "allowFrom": $ALLOW_FROM,
      "profile": {
        "name": "$AGENT_NAME",
        "displayName": "$AGENT_NAME",
        "about": "Self-sovereign AI agent powered by SSOP ⚡"
      }
    }
  },
  "gateway": {
    "port": $GATEWAY_PORT,
    "mode": "local",
    "auth": {
      "mode": "token",
      "token": "$GW_TOKEN"
    }
  }
}
EOFCONFIG

# --- Export env for openclaw ---
export NOSTR_PRIVATE_KEY="$NOSTR_NSEC"
export NODE_OPTIONS="--dns-result-order=ipv4first"

# Find openclaw binary
OPENCLAW_BIN=$(which openclaw 2>/dev/null || echo "")
if [ -z "$OPENCLAW_BIN" ]; then
    # Check common npm global paths
    for candidate in /usr/local/bin/openclaw /usr/lib/node_modules/.bin/openclaw /usr/bin/openclaw; do
        if [ -x "$candidate" ]; then
            OPENCLAW_BIN="$candidate"
            break
        fi
    done
fi

if [ -z "$OPENCLAW_BIN" ]; then
    echo "ERROR: openclaw binary not found in PATH or common locations"
    echo "PATH=$PATH"
    ls -la /usr/local/bin/open* 2>/dev/null || echo "Nothing in /usr/local/bin/open*"
    ls -la /usr/lib/node_modules/.bin/open* 2>/dev/null || echo "Nothing in node_modules/.bin/open*"
    exit 1
fi

echo "Config written. Starting OpenClaw gateway..."
echo "Using: $OPENCLAW_BIN"
exec "$OPENCLAW_BIN" gateway
