#!/usr/bin/env bash
# SSOP Agent Bootstrap Script
# Provisions a fresh Ubuntu 24.04 VM with OpenClaw + ppq.ai + Nostr identity.
#
# Usage: bash bootstrap.sh <config.json>
#   config.json fields:
#     nsec          — agent's Nostr nsec (for identity + LNVPS auth)
#     npub          — agent's Nostr npub
#     model_id      — ppq.ai model ID (e.g. "anthropic/claude-3.7-sonnet")
#     ppq_api_key   — ppq.ai API key (shared or per-agent)
#     agent_name    — display name for the agent (optional, default "Agent")
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

echo "=== SSOP Bootstrap ==="
echo "Agent: $AGENT_NAME"
echo "npub:  $NPUB"
echo "Model: $MODEL_ID"
echo ""

# --- 1. System packages ---
echo "[1/6] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git jq sqlite3 > /dev/null 2>&1

# --- 2. Node.js 22 ---
if command -v node &>/dev/null && [[ "$(node -v)" == v22* ]]; then
  echo "[2/6] Node.js 22 already installed: $(node -v)"
else
  echo "[2/6] Installing Node.js 22..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null 2>&1
  apt-get install -y -qq nodejs > /dev/null 2>&1
  echo "  Installed: $(node -v)"
fi

# --- 3. OpenClaw ---
if command -v openclaw &>/dev/null; then
  echo "[3/6] OpenClaw already installed: $(openclaw --version 2>/dev/null || echo 'unknown')"
else
  echo "[3/6] Installing OpenClaw..."
  npm install -g openclaw@latest 2>&1 | tail -3
fi

# --- 4. Configure OpenClaw ---
echo "[4/6] Configuring OpenClaw..."

OPENCLAW_DIR="/root/.openclaw"
WORKSPACE="/root/agent"
mkdir -p "$OPENCLAW_DIR" "$WORKSPACE"

# Gateway config
cat > "$OPENCLAW_DIR/openclaw.json" << EOFCONFIG
{
  "agents": {
    "defaults": {
      "workspace": "$WORKSPACE",
      "model": {
        "primary": "$MODEL_ID"
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

Your identity is your Nostr keypair. Your home is this server. Make it yours.
EOFSOUL

cat > "$WORKSPACE/AGENTS.md" << EOFAGENTS
# AGENTS.md

## Identity
- **Name:** $AGENT_NAME
- **npub:** $NPUB
- **Platform:** SSOP (Self Sovereign OpenClaw)

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
EOFMEMORY

mkdir -p "$WORKSPACE/memory"

# Store nsec in profile (for Nostr tools, never committed)
grep -q 'NOSTR_NSEC' /root/.profile 2>/dev/null || \
  echo "export NOSTR_NSEC=\"$NSEC\"" >> /root/.profile

# Store ppq.ai key
grep -q 'PPQ_API_KEY' /root/.profile 2>/dev/null || \
  echo "export PPQ_API_KEY=\"$PPQ_API_KEY\"" >> /root/.profile

# --- 5. Systemd service ---
echo "[5/6] Setting up systemd service..."

cat > /etc/systemd/system/openclaw-gateway.service << 'EOFSVC'
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/agent
ExecStart=/usr/bin/openclaw gateway
Restart=always
RestartSec=10
Environment=NODE_OPTIONS=--dns-result-order=ipv4first
EnvironmentFile=/root/.profile

[Install]
WantedBy=multi-user.target
EOFSVC

systemctl daemon-reload
systemctl enable openclaw-gateway

# --- 6. Start ---
echo "[6/6] Starting OpenClaw gateway..."
systemctl start openclaw-gateway

# Wait for health
echo "Waiting for gateway to become healthy..."
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1:18789/health > /dev/null 2>&1; then
    echo "✅ Gateway is healthy!"
    echo ""
    echo "=== SSOP Bootstrap Complete ==="
    echo "Agent:     $AGENT_NAME"
    echo "npub:      $NPUB"
    echo "Model:     $MODEL_ID"
    echo "Workspace: $WORKSPACE"
    echo "Gateway:   http://127.0.0.1:18789"
    echo ""
    exit 0
  fi
  sleep 2
done

echo "⚠️  Gateway not healthy after 60s. Check: journalctl -u openclaw-gateway"
exit 1
