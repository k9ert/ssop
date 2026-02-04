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

# --- 0a. Expand partition if needed (LNVPS cloud images ship with small partitions) ---
ROOT_DEV=$(findmnt -n -o SOURCE /)
DISK_DEV=$(lsblk -no PKNAME "$ROOT_DEV" 2>/dev/null | head -1)
if [ -n "$DISK_DEV" ]; then
  PART_NUM=$(echo "$ROOT_DEV" | grep -o '[0-9]*$')
  if command -v growpart &>/dev/null; then
    growpart "/dev/$DISK_DEV" "$PART_NUM" 2>/dev/null && resize2fs "$ROOT_DEV" 2>/dev/null && echo "[0a] Expanded partition $ROOT_DEV" || true
  else
    apt-get update -qq && apt-get install -y -qq cloud-guest-utils > /dev/null 2>&1
    growpart "/dev/$DISK_DEV" "$PART_NUM" 2>/dev/null && resize2fs "$ROOT_DEV" 2>/dev/null && echo "[0a] Expanded partition $ROOT_DEV" || true
  fi
fi

# --- 0b. Swap for low-memory machines ---
TOTAL_MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
if [ "$TOTAL_MEM_MB" -lt 2048 ] && [ ! -f /swapfile ]; then
  echo "[0b] Low memory (${TOTAL_MEM_MB}MB) — creating 2GB swap..."
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile > /dev/null
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
fi

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
echo "[1/9] Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl git jq sqlite3 > /dev/null 2>&1

# --- 2. Node.js 22 ---
if command -v node &>/dev/null && [[ "$(node -v)" == v22* ]]; then
  echo "[2/9] Node.js 22 already installed: $(node -v)"
else
  echo "[2/9] Installing Node.js 22..."
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null 2>&1
  apt-get install -y -qq nodejs > /dev/null 2>&1
  echo "  Installed: $(node -v)"
fi

# --- 3. OpenClaw ---
if command -v openclaw &>/dev/null; then
  echo "[3/9] OpenClaw already installed: $(openclaw --version 2>/dev/null || echo 'unknown')"
else
  echo "[3/9] Installing OpenClaw..."
  npm install -g openclaw@latest 2>&1 | tail -3
fi

# --- 4a. Install Nostr plugin ---
echo "[4/9] Installing Nostr channel plugin..."
openclaw plugins install @openclaw/nostr 2>&1 | tail -3 || echo "  (may already be installed)"

# --- 4b. Install nostr-tools globally (required by the Nostr plugin at runtime) ---
# Workaround for: https://github.com/openclaw/openclaw/issues/8670
# The @openclaw/nostr plugin requires nostr-tools but doesn't declare it as a dependency
echo "  Installing nostr-tools dependency (openclaw#8670 workaround)..."
npm install -g nostr-tools 2>&1 | tail -1 || true

# --- 4b2. Hot-patch nostr-bus.ts: subscribeMany double-wraps filter array ---
# Workaround for: https://github.com/openclaw/openclaw/issues/7448
# The plugin calls pool.subscribeMany(relays, [filter], ...) but subscribeMany already wraps,
# resulting in [[filter]] which relays reject with 'bad req'
NOSTR_BUS="/usr/lib/node_modules/openclaw/extensions/nostr/src/nostr-bus.ts"
if [ -f "$NOSTR_BUS" ] && grep -q 'pool\.subscribeMany' "$NOSTR_BUS"; then
  echo "  Patching nostr-bus.ts (openclaw#7448: subscribeMany → subscribe)..."
  # Original: pool.subscribeMany(relays, [{ kinds: [4], "#p": [pk], since }], {
  # Fixed:    pool.subscribe(relays, { kinds: [4], "#p": [pk], since }, {
  sed -i 's/pool\.subscribeMany(relays, \[\({ kinds: \[4\], "#p": \[pk\], since }\)\], {/pool.subscribe(relays, \1, {/' "$NOSTR_BUS"
  echo "  Done"
elif [ -f "$NOSTR_BUS" ]; then
  echo "  SKIP: nostr-bus.ts already patched or different structure"
fi

# --- 4c. Hot-patch Nostr plugin: handleInboundMessage not a function ---
# Workaround for: https://github.com/openclaw/openclaw/issues/7449
# Also related: https://github.com/openclaw/openclaw/issues/4547
# The plugin calls runtime.channel.reply.handleInboundMessage() which doesn't exist.
# This patch replaces the broken onMessage handler with a working implementation using
# dispatchReplyWithBufferedBlockDispatcher (the correct internal API).
echo "  Applying Nostr DM hot-patch (openclaw#7449 workaround)..."
NOSTR_CHANNEL="/usr/lib/node_modules/openclaw/extensions/nostr/src/channel.ts"
if [ -f "$NOSTR_CHANNEL" ]; then
  python3 - "$NOSTR_CHANNEL" << 'HOTPATCH_PY'
import sys, re

channel_path = sys.argv[1]
with open(channel_path, 'r') as f:
    content = f.read()

# Only patch if the broken handleInboundMessage pattern exists or if onMessage is the original
if 'handleInboundMessage' in content or ('onMessage: async (senderPubkey, text, reply)' in content and 'dispatcherOptions' not in content):
    # Find onMessage handler boundaries
    start = content.find('onMessage: async (senderPubkey, text, reply) => {')
    if start == -1:
        print("  SKIP: onMessage handler not found")
        sys.exit(0)
    
    # Find the next onError handler (end of onMessage)
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

    # Remove duplicate onError if present from previous patches
    content_new = content[:start] + new_handler + content[end:]
    dup = "        onError: (error, context) => {\\n          ctx.log?.error"
    with open(channel_path, 'w') as f:
        f.write(content_new)
    print("  Hot-patch applied successfully")
elif 'dispatcherOptions' in content:
    print("  SKIP: already patched")
else:
    print("  SKIP: unrecognized channel.ts structure")
HOTPATCH_PY
else
  echo "  WARN: channel.ts not found, skipping hot-patch"
fi

# --- 4d. Fix normalizePubkey for nostr-tools 2.23+ ---
# Workaround for: https://github.com/openclaw/openclaw/issues/8570
# In nostr-tools 2.23+, nip19.decode().data returns a hex string, not Uint8Array.
# The plugin's normalizePubkey() assumes Uint8Array and produces garbage hex,
# breaking allowFrom matching (owners can't talk to their own agents).
echo "  Fixing normalizePubkey (openclaw#8570 workaround)..."
NOSTR_BUS="/usr/lib/node_modules/openclaw/extensions/nostr/src/nostr-bus.ts"
if [ -f "$NOSTR_BUS" ]; then
  if grep -q 'typeof decoded.data === "string"' "$NOSTR_BUS"; then
    echo "  SKIP: normalizePubkey already fixed"
  else
    # In nostr-tools 2.23+, nip19.decode().data returns string (hex) not Uint8Array
    # Add type check to handle both cases
    sed -i 's|// Convert Uint8Array to hex string|// Handle both string (nostr-tools 2.23+) and Uint8Array (older) return types\n    if (typeof decoded.data === "string") {\n      return decoded.data.toLowerCase();\n    }\n    // Convert Uint8Array to hex string (legacy)|' "$NOSTR_BUS"
    echo "  normalizePubkey patched"
  fi
else
  echo "  WARN: nostr-bus.ts not found"
fi

# --- 5. Configure OpenClaw ---
echo "[5/9] Configuring OpenClaw..."

OPENCLAW_DIR="/root/.openclaw"
WORKSPACE="/root/agent"
ENV_FILE="/root/.openclaw/env"
mkdir -p "$OPENCLAW_DIR" "$WORKSPACE" "$WORKSPACE/memory"

# Environment file for systemd (KEY=VALUE format, no export, no quotes)
# Limit Node.js heap on low-memory machines to prevent OOM
# 768MB heap works with 2GB swap on 1GB machines; 384 was too small
NODE_OPTS="--dns-result-order=ipv4first"
if [ "$TOTAL_MEM_MB" -lt 2048 ]; then
  NODE_OPTS="$NODE_OPTS --max-old-space-size=768"
fi

# Generate a random gateway auth token
GW_TOKEN=$(openssl rand -hex 24)
cat > "$ENV_FILE" << EOFENV
NOSTR_PRIVATE_KEY=$NSEC
PPQ_API_KEY=$PPQ_API_KEY
NODE_OPTIONS=$NODE_OPTS
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
echo "[6/9] Setting up systemd service..."

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

# --- 7. Install SSOP skills ---
echo "[7/9] Installing SSOP skills..."
cd "$WORKSPACE"
mkdir -p skills scripts
if curl -sfL https://ssop.pages.dev/install.sh -o /tmp/ssop-install.sh; then
  bash /tmp/ssop-install.sh 2>&1 | tail -5
else
  echo "  WARN: Could not fetch SSOP skill installer"
fi

# --- 8. Start ---
echo "[8/9] Starting OpenClaw gateway..."
systemctl restart openclaw-gateway

# --- 9. Wait for health ---
echo "[9/9] Waiting for gateway to become healthy..."
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
    echo "DM policy: pairing (owner auto-allowed)"
    echo ""
    echo "Send a Nostr DM to $NPUB to talk to your agent!"
    exit 0
  fi
  sleep 2
done

echo "⚠️  Gateway not healthy after 60s. Check: journalctl -u openclaw-gateway"
exit 1
