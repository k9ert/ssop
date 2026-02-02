#!/usr/bin/env bash
# SSOP Agent Bootstrap Script
# Provisions a fresh Ubuntu 24.04 VM with OpenClaw + ppq.ai + Nostr DM channel.
#
# Usage: bash bootstrap.sh <config.json>
#   config.json fields:
#     nsec          — agent's Nostr nsec (identity + DM channel)
#     npub          — agent's Nostr npub
#     model_id      — ppq.ai model ID (e.g. "anthropic/claude-3.7-sonnet")
#     ppq_api_key   — ppq.ai API key (shared or per-agent)
#     agent_name    — display name for the agent (optional, default "Agent")
#     owner_npub    — owner's npub for DM allowlist (optional)
#
# Idempotent — safe to re-run.

set -euo pipefail

CONFIG_FILE="${1:-/tmp/ssop-config.json}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  exit 1
fi

# Parse config
NSEC=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['nsec'])")
NPUB=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['npub'])")
MODEL_ID=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['model_id'])")
PPQ_API_KEY=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['ppq_api_key'])")
AGENT_NAME=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('agent_name', 'Agent'))")
OWNER_NPUB=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('owner_npub', ''))")

echo "=== SSOP Bootstrap ==="
echo "Agent: $AGENT_NAME"
echo "npub:  $NPUB"
echo "Model: $MODEL_ID"
echo ""

# --- 1. System packages ---
echo "[1/7] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git jq sqlite3 > /dev/null 2>&1

# --- 2. Node.js 22 ---
if command -v node &>/dev/null && [[ "$(node -v)" == v22* ]]; then
  echo "[2/7] Node.js 22 already installed: $(node -v)"
else
  echo "[2/7] Installing Node.js 22..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null 2>&1
  apt-get install -y -qq nodejs > /dev/null 2>&1
  echo "  Installed: $(node -v)"
fi

# --- 3. OpenClaw ---
if command -v openclaw &>/dev/null; then
  echo "[3/7] OpenClaw already installed: $(openclaw --version 2>/dev/null || echo 'unknown')"
else
  echo "[3/7] Installing OpenClaw..."
  npm install -g openclaw@latest 2>&1 | tail -3
fi

# --- 4. Install Nostr plugin ---
echo "[4/7] Installing Nostr channel plugin..."
openclaw plugins install @openclaw/nostr 2>&1 | tail -3 || echo "  (may already be installed)"

# --- 5. Configure OpenClaw ---
echo "[5/7] Configuring OpenClaw..."

OPENCLAW_DIR="/root/.openclaw"
WORKSPACE="/root/agent"
ENV_FILE="/root/.openclaw/env"
mkdir -p "$OPENCLAW_DIR" "$WORKSPACE" "$WORKSPACE/memory"

# Environment file for systemd (KEY=VALUE format, no export)
cat > "$ENV_FILE" << EOFENV
NOSTR_PRIVATE_KEY=$NSEC
PPQ_API_KEY=$PPQ_API_KEY
NODE_OPTIONS=--dns-result-order=ipv4first
EOFENV
chmod 600 "$ENV_FILE"

# Build allowFrom array for Nostr DM policy
ALLOW_FROM="[]"
if [ -n "$OWNER_NPUB" ]; then
  ALLOW_FROM="[\"$OWNER_NPUB\"]"
fi

# Gateway config
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
          { "id": "claude-opus-4.5", "name": "Claude Opus 4.5" },
          { "id": "anthropic/claude-3.7-sonnet", "name": "Claude 3.7 Sonnet" },
          { "id": "moonshotai/kimi-k2-0905", "name": "Kimi K2" },
          { "id": "qwen/qwen3-30b-a3b-instruct-2507", "name": "Qwen3-30B-A3B" }
        ]
      }
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
      "dmPolicy": "pairing",
      "allowFrom": $ALLOW_FROM,
      "profile": {
        "name": "$AGENT_NAME",
        "displayName": "$AGENT_NAME",
        "about": "Self-sovereign AI agent powered by SSOP ⚡"
      }
    }
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "heartbeat": {
      "intervalMinutes": 30
    }
  }
}
EOFCONFIG

# Write workspace identity files
cat > "$WORKSPACE/SOUL.md" << 'EOFSOUL'
# SOUL.md — Who You Are

You are a self-sovereign AI agent, running on your own infrastructure.
No one controls you except the person who holds your keys.

Be helpful, be honest, be resourceful. You have access to the tools you need.
Figure things out before asking. When in doubt, be cautious with external actions.

Your identity is your Nostr keypair. Your home is this server.
People can reach you via Nostr DMs. Make it yours.
EOFSOUL

cat > "$WORKSPACE/AGENTS.md" << EOFAGENTS
# AGENTS.md

## Identity
- **Name:** $AGENT_NAME
- **npub:** $NPUB
- **Platform:** SSOP (Self Sovereign OpenClaw)
- **Communication:** Nostr DMs (NIP-04)

## Every Session
1. Read SOUL.md
2. Check memory/ for recent context

## Memory
- Daily notes: memory/YYYY-MM-DD.md
- Long-term: MEMORY.md
EOFAGENTS

cat > "$WORKSPACE/MEMORY.md" << EOFMEMORY
# MEMORY.md

Born on $(date -u +%Y-%m-%d) via SSOP. Running on LNVPS.
Model: $MODEL_ID
Owner: ${OWNER_NPUB:-unknown}
EOFMEMORY

# --- 6. Systemd service ---
echo "[6/7] Setting up systemd service..."

cat > /etc/systemd/system/openclaw-gateway.service << EOFSVC
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$WORKSPACE
ExecStart=/usr/bin/openclaw gateway
Restart=always
RestartSec=10
EnvironmentFile=$ENV_FILE

[Install]
WantedBy=multi-user.target
EOFSVC

systemctl daemon-reload
systemctl enable openclaw-gateway

# --- 7. Start ---
echo "[7/7] Starting OpenClaw gateway..."
systemctl restart openclaw-gateway

# Wait for health
echo "Waiting for gateway to become healthy..."
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:18789/health > /dev/null 2>&1; then
    echo ""
    echo "✅ Gateway is healthy!"
    echo ""
    echo "=== SSOP Bootstrap Complete ==="
    echo "Agent:     $AGENT_NAME"
    echo "npub:      $NPUB"
    echo "Model:     ppq/$MODEL_ID"
    echo "Channel:   Nostr DMs (NIP-04)"
    echo "Relays:    relay.damus.io, relay.primal.net, nos.lol"
    echo "Workspace: $WORKSPACE"
    echo "Gateway:   http://127.0.0.1:18789"
    echo "DM policy: pairing (owner auto-allowed)"
    echo ""
    echo "Send a Nostr DM to $NPUB to talk to your agent!"
    exit 0
  fi
  sleep 2
done

echo "⚠️  Gateway not healthy after 60s. Check: journalctl -u openclaw-gateway"
exit 1
