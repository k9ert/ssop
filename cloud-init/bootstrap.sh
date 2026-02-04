#!/usr/bin/env bash
# SSOP Agent Bootstrap Script (non-root)
# Provisions a VM with OpenClaw + ppq.ai + Nostr DM channel.
# Does NOT require root — uses local npm install and user systemd.
#
# Prerequisites (must be installed by cloud-init or manually):
#   - Node.js 22+
#   - python3 (for config parsing and hot-patches)
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

# --- Paths (all user-local, no root needed) ---
INSTALL_DIR="$HOME/openclaw"
WORKSPACE="$HOME/agent"
OPENCLAW_DIR="$HOME/.openclaw"
ENV_FILE="$HOME/.openclaw/env"
SYSTEMD_DIR="$HOME/.config/systemd/user"
NODE_MODULES="$INSTALL_DIR/node_modules"

CONFIG_FILE="${1:-/tmp/ssop-config.json}"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  exit 1
fi

# Check Node.js
if ! command -v node &>/dev/null; then
  echo "ERROR: Node.js not found. Install Node.js 22+ first."
  echo "  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -"
  echo "  sudo apt-get install -y nodejs"
  exit 1
fi

NODE_VERSION=$(node -v | cut -d. -f1 | tr -d 'v')
if [ "$NODE_VERSION" -lt 22 ]; then
  echo "ERROR: Node.js 22+ required, found $(node -v)"
  exit 1
fi

# Parse config
NSEC=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['nsec'])")
NPUB=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['npub'])")
MODEL_ID=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['model_id'])")
PPQ_API_KEY=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['ppq_api_key'])")
AGENT_NAME=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('agent_name', 'Agent'))")
OWNER_NPUB=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('owner_npub', ''))")

echo "=== SSOP Bootstrap (non-root) ==="
echo "Agent: $AGENT_NAME"
echo "npub:  $NPUB"
echo "Model: $MODEL_ID"
echo ""

# --- 1. Create directories ---
echo "[1/8] Creating directories..."
mkdir -p "$INSTALL_DIR" "$WORKSPACE" "$WORKSPACE/memory" "$OPENCLAW_DIR" "$SYSTEMD_DIR"

# --- 2. Install OpenClaw locally ---
echo "[2/8] Installing OpenClaw (local)..."
cd "$INSTALL_DIR"
if [ -f "$NODE_MODULES/.bin/openclaw" ]; then
  echo "  OpenClaw already installed"
else
  npm install openclaw@latest 2>&1 | tail -5
fi

# Add to PATH for this session
export PATH="$NODE_MODULES/.bin:$PATH"

# --- 3. Install Nostr plugin ---
echo "[3/8] Installing Nostr channel plugin..."
openclaw plugins install @openclaw/nostr 2>&1 | tail -3 || echo "  (may already be installed)"

# --- 3b. Install nostr-tools (local) ---
# Workaround for: https://github.com/openclaw/openclaw/issues/8670
# The @openclaw/nostr plugin requires nostr-tools but doesn't declare it as a dependency
echo "  Installing nostr-tools dependency (openclaw#8670 workaround)..."
cd "$INSTALL_DIR" && npm install nostr-tools 2>&1 | tail -1 || true

# --- 4. Apply hot-patches ---
echo "[4/8] Applying Nostr plugin hot-patches..."

# Find where openclaw installed the nostr extension
# Could be in node_modules/openclaw/extensions or a separate extensions dir
NOSTR_EXT=""
for candidate in \
  "$NODE_MODULES/openclaw/extensions/nostr/src" \
  "$NODE_MODULES/@openclaw/nostr/src" \
  "$HOME/.openclaw/extensions/nostr/src"; do
  if [ -d "$candidate" ]; then
    NOSTR_EXT="$candidate"
    break
  fi
done

if [ -z "$NOSTR_EXT" ]; then
  echo "  WARN: Nostr extension not found, skipping hot-patches"
else
  echo "  Found Nostr extension at: $NOSTR_EXT"
  
  # --- 4a. Hot-patch: subscribeMany double-wraps filter array ---
  # Workaround for: https://github.com/openclaw/openclaw/issues/7448
  NOSTR_BUS="$NOSTR_EXT/nostr-bus.ts"
  if [ -f "$NOSTR_BUS" ] && grep -q 'pool\.subscribeMany' "$NOSTR_BUS"; then
    echo "  Patching nostr-bus.ts (openclaw#7448: subscribeMany → subscribe)..."
    sed -i 's/pool\.subscribeMany(relays, \[\({ kinds: \[4\], "#p": \[pk\], since }\)\], {/pool.subscribe(relays, \1, {/' "$NOSTR_BUS"
  elif [ -f "$NOSTR_BUS" ]; then
    echo "  SKIP: nostr-bus.ts already patched or different structure"
  fi

  # --- 4b. Hot-patch: handleInboundMessage not a function ---
  # Workaround for: https://github.com/openclaw/openclaw/issues/7449
  # Also: https://github.com/openclaw/openclaw/issues/4547
  NOSTR_CHANNEL="$NOSTR_EXT/channel.ts"
  if [ -f "$NOSTR_CHANNEL" ]; then
    python3 - "$NOSTR_CHANNEL" << 'HOTPATCH_PY'
import sys

channel_path = sys.argv[1]
with open(channel_path, 'r') as f:
    content = f.read()

if 'handleInboundMessage' in content or ('onMessage: async (senderPubkey, text, reply)' in content and 'dispatcherOptions' not in content):
    start = content.find('onMessage: async (senderPubkey, text, reply) => {')
    if start == -1:
        print("  SKIP: onMessage handler not found")
        sys.exit(0)
    end = content.find('        onError: (error, context) => {', start + 50)
    if end == -1:
        print("  SKIP: onError boundary not found")
        sys.exit(0)

    new_handler = """onMessage: async (senderPubkey, text, reply) => {
          ctx.log?.debug(`[${account.accountId}] DM from ${senderPubkey}: ${text.slice(0, 50)}...`);
          const runtime = getNostrRuntime();
          const cfg = runtime.config.loadConfig();
          const nostrCfg = (cfg as any).channels?.nostr ?? {};
          const dmPolicy = nostrCfg.dmPolicy ?? "pairing";
          const configAllowFrom = (nostrCfg.allowFrom ?? []).map((e: any) => String(e).trim()).filter(Boolean);
          let storeAllowFrom: string[] = [];
          try { storeAllowFrom = await runtime.channel.pairing.readAllowFromStore("nostr"); } catch {}
          const allAllowed = [...configAllowFrom, ...storeAllowFrom];
          const hasWildcard = allAllowed.includes("*");
          const normalizedSender = normalizePubkey(senderPubkey);
          const isAllowed = dmPolicy === "open" || hasWildcard ||
            allAllowed.some((a: string) => { try { return normalizePubkey(a) === normalizedSender; } catch { return a === senderPubkey; } });
          if (!isAllowed) {
            if (dmPolicy === "pairing") {
              try {
                const { code, created } = await runtime.channel.pairing.upsertPairingRequest({ channel: "nostr", id: normalizedSender, meta: { name: normalizedSender.slice(0, 12) + "..." } });
                if (created) {
                  ctx.log?.info(`[${account.accountId}] Nostr pairing request from ${normalizedSender}, code=${code}`);
                  await reply(runtime.channel.pairing.buildPairingReply({ channel: "nostr", idLine: `Your Nostr pubkey: ${normalizedSender}`, code }));
                }
              } catch (err: any) { ctx.log?.error(`[${account.accountId}] pairing error: ${err.message}`); }
            } else { ctx.log?.debug(`[${account.accountId}] blocked ${normalizedSender} (dmPolicy=${dmPolicy})`); }
            return;
          }
          const route = runtime.channel.routing.resolveAgentRoute({ cfg, channel: "nostr", accountId: account.accountId, peer: { kind: "dm" as const, id: normalizedSender } });
          const ctxPayload = runtime.channel.reply.finalizeInboundContext({
            Body: text, RawBody: text, CommandBody: text, From: normalizedSender, To: account.publicKey,
            SessionKey: route.sessionKey, AccountId: route.accountId, MessageSid: `nostr-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
            ChatType: "direct", ConversationLabel: normalizedSender, SenderName: normalizedSender.slice(0, 12) + "...",
            SenderId: normalizedSender, CommandAuthorized: true, Provider: "nostr", Surface: "nostr",
            OriginatingChannel: "nostr", OriginatingTo: normalizedSender, Timestamp: Date.now(),
          });
          try {
            const storePath = runtime.channel.session.resolveStorePath(cfg, route.agentId);
            await runtime.channel.session.recordSessionMetaFromInbound({ storePath, sessionKey: route.sessionKey, ctx: ctxPayload });
          } catch (err: any) { ctx.log?.warn(`[${account.accountId}] session meta: ${err.message}`); }
          try {
            await runtime.channel.reply.dispatchReplyWithBufferedBlockDispatcher({
              ctx: ctxPayload, cfg,
              dispatcherOptions: {
                deliver: async (payload: any, _info: any) => { const t = payload?.text?.trim(); if (t) await reply(t); },
                onReplyStart: undefined, onIdle: undefined,
                onSkip: (_p: any, info: any) => { ctx.log?.debug(`[${account.accountId}] reply skipped: ${info?.reason}`); },
                onError: (err: any, info: any) => { ctx.log?.error(`[${account.accountId}] dispatch error (${info?.kind}): ${String(err)}`); },
              },
            });
          } catch (err: any) {
            ctx.log?.error(`[${account.accountId}] dispatch error: ${err.message}`);
            try { await reply("I encountered an error processing your message."); } catch {}
          }
        },
        """
    with open(channel_path, 'w') as f:
        f.write(content[:start] + new_handler + content[end:])
    print("  Hot-patch applied (openclaw#7449)")
elif 'dispatcherOptions' in content:
    print("  SKIP: already patched")
else:
    print("  SKIP: unrecognized channel.ts structure")
HOTPATCH_PY
  fi

  # --- 4c. Hot-patch: normalizePubkey for nostr-tools 2.23+ ---
  # Workaround for: https://github.com/openclaw/openclaw/issues/8570
  if [ -f "$NOSTR_BUS" ]; then
    if grep -q 'typeof decoded.data === "string"' "$NOSTR_BUS"; then
      echo "  SKIP: normalizePubkey already fixed"
    else
      sed -i 's|// Convert Uint8Array to hex string|// Handle both string (nostr-tools 2.23+) and Uint8Array (older)\n    if (typeof decoded.data === "string") {\n      return decoded.data.toLowerCase();\n    }\n    // Convert Uint8Array to hex string (legacy)|' "$NOSTR_BUS"
      echo "  Patched normalizePubkey (openclaw#8570)"
    fi
  fi
fi

# --- 5. Configure OpenClaw ---
echo "[5/8] Configuring OpenClaw..."

# Environment file
TOTAL_MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
NODE_OPTS="--dns-result-order=ipv4first"
if [ "$TOTAL_MEM_MB" -lt 2048 ]; then
  NODE_OPTS="$NODE_OPTS --max-old-space-size=768"
fi

GW_TOKEN=$(openssl rand -hex 24)
cat > "$ENV_FILE" << EOFENV
NOSTR_PRIVATE_KEY=$NSEC
PPQ_API_KEY=$PPQ_API_KEY
NODE_OPTIONS=$NODE_OPTS
PATH=$NODE_MODULES/.bin:\$PATH
EOFENV
chmod 600 "$ENV_FILE"

# Build allowFrom array
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
          { "id": "moonshotai/kimi-k2-0905", "name": "Kimi K2" }
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
    "auth": {
      "mode": "token",
      "token": "$GW_TOKEN"
    }
  }
}
EOFCONFIG

# Workspace identity files
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

Born on $(date -u +%Y-%m-%d) via SSOP.
Model: $MODEL_ID
Owner: ${OWNER_NPUB:-unknown}
EOFMEMORY

# --- 6. User systemd service ---
echo "[6/8] Setting up user systemd service..."

cat > "$SYSTEMD_DIR/openclaw-gateway.service" << EOFSVC
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
WorkingDirectory=$WORKSPACE
ExecStart=$NODE_MODULES/.bin/openclaw gateway
Restart=always
RestartSec=10
EnvironmentFile=$ENV_FILE

[Install]
WantedBy=default.target
EOFSVC

# Enable lingering so user services run without login
if command -v loginctl &>/dev/null; then
  loginctl enable-linger "$(whoami)" 2>/dev/null || true
fi

systemctl --user daemon-reload
systemctl --user enable openclaw-gateway

# --- 7. Install SSOP skills ---
echo "[7/8] Installing SSOP skills..."
cd "$WORKSPACE"
mkdir -p skills scripts

# --- 8. Start ---
echo "[8/8] Starting OpenClaw gateway..."
systemctl --user restart openclaw-gateway

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
    echo "GW Token:  $GW_TOKEN"
    echo ""
    echo "Send a Nostr DM to $NPUB to talk to your agent!"
    exit 0
  fi
  sleep 2
done

echo "⚠️  Gateway not healthy after 60s. Check: journalctl --user -u openclaw-gateway"
exit 1
