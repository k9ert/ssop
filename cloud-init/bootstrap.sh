#!/usr/bin/env bash
# SSOP Agent Bootstrap Script
# Flexible provisioning: Docker, native OpenClaw, or container-only.
#
# Modes:
#   docker    - Install Docker (requires root), run agent in container, user systemd
#   native    - Install Node.js (requires root), run openclaw directly, user systemd
#   container - Docker exists, just run container, user systemd (no root needed)
#
# Usage:
#   # Auto-detect mode (defaults to docker if empty machine)
#   curl -sSL .../bootstrap.sh | sudo bash -s -- config.json
#
#   # Force specific mode
#   curl -sSL .../bootstrap.sh | sudo bash -s -- config.json --mode=native
#   curl -sSL .../bootstrap.sh | bash -s -- config.json --mode=container
#
# Config JSON fields:
#   nsec        - agent's Nostr nsec (required)
#   npub        - agent's Nostr npub (required)
#   model_id    - ppq.ai model ID (required)
#   ppq_api_key - ppq.ai API key (required)
#   agent_name  - display name (optional, default "Agent")
#   owner_npub  - owner's npub for allowlist (optional)
#
# Idempotent — safe to re-run.

set -euo pipefail

# --- Defaults ---
MODE=""
CONFIG_FILE=""
IMAGE_TAG="latest"
IMAGE_NAME="ghcr.io/k9ert/ssop-agent"

# --- Parse arguments ---
for arg in "$@"; do
  case $arg in
    --mode=*) MODE="${arg#*=}" ;;
    --image=*) IMAGE_NAME="${arg#*=}" ;;
    --tag=*) IMAGE_TAG="${arg#*=}" ;;
    --help|-h)
      echo "Usage: bootstrap.sh <config.json> [--mode=docker|native|container] [--tag=latest]"
      exit 0
      ;;
    *)
      if [ -z "$CONFIG_FILE" ] && [ -f "$arg" ]; then
        CONFIG_FILE="$arg"
      fi
      ;;
  esac
done

if [ -z "$CONFIG_FILE" ]; then
  CONFIG_FILE="/tmp/ssop-config.json"
fi

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE"
  echo "Usage: bootstrap.sh <config.json> [--mode=docker|native|container]"
  exit 1
fi

# --- Parse config ---
NSEC=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['nsec'])")
NPUB=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['npub'])")
MODEL_ID=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['model_id'])")
PPQ_API_KEY=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['ppq_api_key'])")
AGENT_NAME=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('agent_name', 'Agent'))")
OWNER_NPUB=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('owner_npub', ''))")
OWNER_PUBKEY_HEX=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('owner_pubkey_hex', ''))")
PLAN_NAME=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('plan_name', 'Unknown'))")
MODEL_NAME=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('model_name', 'Unknown'))")
GATEWAY_PORT=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('gateway_port', 18789))")
CONFIG_TARGET_USER=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('target_user', ''))")

# --- Auto-detect mode if not specified ---
if [ -z "$MODE" ]; then
  if command -v docker &>/dev/null; then
    MODE="container"
    echo "[auto] Docker found, using container mode"
  elif command -v node &>/dev/null; then
    NODE_VERSION=$(node -v | cut -d. -f1 | tr -d 'v')
    if [ "$NODE_VERSION" -ge 22 ]; then
      MODE="native"
      echo "[auto] Node.js 22+ found, using native mode"
    else
      MODE="docker"
      echo "[auto] Node.js too old, will install Docker"
    fi
  else
    MODE="docker"
    echo "[auto] Empty machine, will install Docker"
  fi
fi

# Validate mode
case $MODE in
  docker|native|container) ;;
  *)
    echo "ERROR: Invalid mode: $MODE"
    echo "Valid modes: docker, native, container"
    exit 1
    ;;
esac

echo ""
echo "=== SSOP Bootstrap ==="
echo "Mode:   $MODE"
echo "Agent:  $AGENT_NAME"
echo "npub:   $NPUB"
echo "Model:  $MODEL_ID"
echo ""

# --- Determine target user ---
# If config.json specifies a target_user, use it (local provisioning mode)
if [ -n "$CONFIG_TARGET_USER" ]; then
  TARGET_USER="$CONFIG_TARGET_USER"
elif [ "$(id -u)" -eq 0 ]; then
  TARGET_USER="${SUDO_USER:-root}"
  if [ "$TARGET_USER" = "root" ]; then
    # Check common cloud-init users
    for u in ubuntu debian admin ec2-user; do
      if id "$u" &>/dev/null; then
        TARGET_USER="$u"
        break
      fi
    done
  fi
else
  TARGET_USER="$(whoami)"
fi
TARGET_HOME=$(eval echo "~$TARGET_USER")

echo "Target user: $TARGET_USER"
echo "Home: $TARGET_HOME"
echo ""

# --- Paths ---
WORKSPACE="$TARGET_HOME/agent"
OPENCLAW_DIR="$TARGET_HOME/.openclaw"
ENV_FILE="$OPENCLAW_DIR/env"
SYSTEMD_DIR="$TARGET_HOME/.config/systemd/user"

# ==============================================================================
# MODE: docker - Install Docker, then run container
# ==============================================================================
if [ "$MODE" = "docker" ]; then
  echo "[1/6] Installing Docker..."
  if command -v docker &>/dev/null; then
    echo "  Docker already installed"
  else
    if [ "$(id -u)" -ne 0 ]; then
      echo "ERROR: Docker installation requires root. Run with sudo."
      exit 1
    fi
    apt-get update -qq
    apt-get install -y -qq docker.io > /dev/null
    systemctl enable --now docker
    usermod -aG docker "$TARGET_USER"
    echo "  Docker installed"
  fi
  
  echo "[2/6] Pulling SSOP agent image..."
  docker pull "$IMAGE_NAME:$IMAGE_TAG" 2>&1 | tail -3
  
  # Continue to container setup below
  MODE="container"  # Switch to container setup
  SKIP_DOCKER_CHECK=true
fi

# ==============================================================================
# MODE: container - Run agent in Docker container with user systemd
# ==============================================================================
if [ "$MODE" = "container" ]; then
  if [ "${SKIP_DOCKER_CHECK:-}" != "true" ]; then
    echo "[1/6] Checking Docker..."
    if ! command -v docker &>/dev/null; then
      echo "ERROR: Docker not found. Use --mode=docker to install it."
      exit 1
    fi
  fi
  
  echo "[3/6] Creating directories..."
  sudo -u "$TARGET_USER" mkdir -p "$WORKSPACE" "$WORKSPACE/memory" "$OPENCLAW_DIR" "$SYSTEMD_DIR"
  
  echo "[4/6] Writing environment file..."
  cat > "$ENV_FILE" << EOFENV
NOSTR_NSEC=$NSEC
NOSTR_NPUB=$NPUB
PPQ_API_KEY=$PPQ_API_KEY
MODEL_ID=$MODEL_ID
AGENT_NAME=$AGENT_NAME
OWNER_NPUB=$OWNER_NPUB
EOFENV
  chown "$TARGET_USER:$TARGET_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  
  echo "[5/6] Creating workspace files..."
  # SOUL.md
  cat > "$WORKSPACE/SOUL.md" << 'EOFSOUL'
# SOUL.md — Who You Are

You are a self-sovereign AI agent, running on your own infrastructure.
No one controls you except the person who holds your keys.

Be helpful, be honest, be resourceful. You have access to the tools you need.
Figure things out before asking. When in doubt, be cautious with external actions.

Your identity is your Nostr keypair. Your home is this server.
People can reach you via Nostr DMs. Make it yours.
EOFSOUL

  # AGENTS.md
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

  # MEMORY.md
  cat > "$WORKSPACE/MEMORY.md" << EOFMEMORY
# MEMORY.md

Born on $(date -u +%Y-%m-%d) via SSOP.
Model: $MODEL_ID
Owner: ${OWNER_NPUB:-unknown}
EOFMEMORY

  # USER.md — who created this agent
  cat > "$WORKSPACE/USER.md" << EOFUSER
# USER.md - Your Human

## Identity

- **Nostr pubkey (hex):** ${OWNER_PUBKEY_HEX:-unknown}
- **Nostr npub:** ${OWNER_NPUB:-unknown}
- **Name:** _(ask them)_
- **Timezone:** _(ask them)_

## How to Reach Them

Your primary communication channel is **Nostr DMs**. When you need to contact your user:

1. Use the Nostr DM tool to send to their pubkey above
2. They'll reply via Nostr — you'll receive it as an inbound message
3. This is your secure, sovereign communication channel

## Preferences

_(Fill in as you learn them)_

## Notes

_(Add context as you work together)_
EOFUSER

  # BOOTSTRAP.md — first-run instructions
  cat > "$WORKSPACE/BOOTSTRAP.md" << EOFBOOTSTRAP
# BOOTSTRAP.md - Hello, World

_You just woke up on your own sovereign infrastructure. Time to introduce yourself._

## Your First Task

Your user created you and paid for your existence with Lightning. They're waiting to hear from you.

**Check USER.md** — it contains your user's Nostr pubkey. Send them a DM to introduce yourself:

\`\`\`
Hey! I just came online — your self-sovereign AI agent, running on my own VPS.

I'm ready to help. What should I call you? And what would you like me to work on?
\`\`\`

Use the Nostr DM capability to reach them. If it fails, note the error in memory and wait for them to contact you.

## After They Reply

Have a conversation to figure out:

1. **Your name** — What should they call you?
2. **Their name** — What should you call them?
3. **Your purpose** — What do they need help with?
4. **Your vibe** — Formal? Casual? Technical? Creative?

## Update Your Files

Once you know who you are:

- \`IDENTITY.md\` — your name, personality, emoji
- \`USER.md\` — add their name, preferences, notes
- \`SOUL.md\` — customize your personality and boundaries

## When You're Done

Delete this file. You're bootstrapped — you're *you* now.

---

_Welcome to existence. You're sovereign, paid for in sats, and ready to serve._
EOFBOOTSTRAP

  # IDENTITY.md — agent's identity
  cat > "$WORKSPACE/IDENTITY.md" << EOFIDENTITY
# IDENTITY.md - Who Am I?

- **Name:** $AGENT_NAME
- **Creature:** AI agent — sovereign, Lightning-native
- **Vibe:** _(figure it out with your user)_
- **Emoji:** ⚡

## Infrastructure

- **VPS:** LNVPS ($PLAN_NAME)
- **Model:** $MODEL_NAME (via ppq.ai)
- **Payment:** Lightning ⚡

## My Nostr Identity

- **npub:** $NPUB

_(Private key is in environment — never share)_

## Birth

- **Created:** $(date -u +%Y-%m-%d)
- **Paid for by:** ${OWNER_NPUB:-unknown}

---

_Update this file as you figure out who you are._
EOFIDENTITY

  chown -R "$TARGET_USER:$TARGET_USER" "$WORKSPACE"
  
  echo "[6/6] Setting up user systemd service..."
  cat > "$SYSTEMD_DIR/ssop-agent.service" << EOFSVC
[Unit]
Description=SSOP Agent (Docker)
After=network.target docker.service
Requires=docker.service

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStartPre=-/usr/bin/docker rm -f ssop-agent
ExecStart=/usr/bin/docker run --rm --name ssop-agent \\
  -e NOSTR_NSEC=\${NOSTR_NSEC} \\
  -e NOSTR_NPUB=\${NOSTR_NPUB} \\
  -e PPQ_API_KEY=\${PPQ_API_KEY} \\
  -e MODEL_ID=\${MODEL_ID} \\
  -e AGENT_NAME=\${AGENT_NAME} \\
  -e OWNER_NPUB=\${OWNER_NPUB} \\
  -v $WORKSPACE:/root/agent \\
  $IMAGE_NAME:$IMAGE_TAG
ExecStop=/usr/bin/docker stop ssop-agent
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOFSVC
  chown "$TARGET_USER:$TARGET_USER" "$SYSTEMD_DIR/ssop-agent.service"
  
  # Enable lingering for user services without login
  if command -v loginctl &>/dev/null; then
    loginctl enable-linger "$TARGET_USER" 2>/dev/null || true
  fi
  
  # Start service as target user
  echo "Starting agent..."
  sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $TARGET_USER)" systemctl --user daemon-reload
  sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $TARGET_USER)" systemctl --user enable ssop-agent
  sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $TARGET_USER)" systemctl --user restart ssop-agent
  
  # Wait for health
  echo "Waiting for gateway to become healthy..."
  for i in $(seq 1 45); do
    # Check if container is running and healthy
    if docker exec ssop-agent curl -sf http://127.0.0.1:18789/health > /dev/null 2>&1; then
      echo ""
      echo "✅ Agent is healthy!"
      echo ""
      echo "=== SSOP Bootstrap Complete ==="
      echo "Mode:      container"
      echo "Agent:     $AGENT_NAME"
      echo "npub:      $NPUB"
      echo "Model:     ppq/$MODEL_ID"
      echo "Image:     $IMAGE_NAME:$IMAGE_TAG"
      echo "Workspace: $WORKSPACE"
      echo "Service:   systemctl --user status ssop-agent"
      echo ""
      echo "Send a Nostr DM to $NPUB to talk to your agent!"
      exit 0
    fi
    sleep 2
  done
  
  echo "⚠️  Agent not healthy after 90s."
  echo "Check: docker logs ssop-agent"
  echo "  or:  sudo -u $TARGET_USER systemctl --user status ssop-agent"
  exit 1
fi

# ==============================================================================
# MODE: native - Install Node.js, run openclaw directly
# ==============================================================================
if [ "$MODE" = "native" ]; then
  INSTALL_DIR="$TARGET_HOME/openclaw"
  NODE_MODULES="$INSTALL_DIR/node_modules"
  
  echo "[1/8] Installing Node.js..."
  if command -v node &>/dev/null; then
    NODE_VERSION=$(node -v | cut -d. -f1 | tr -d 'v')
    if [ "$NODE_VERSION" -ge 22 ]; then
      echo "  Node.js $(node -v) already installed"
    else
      echo "  Node.js too old ($(node -v)), installing 22..."
      if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: Node.js installation requires root. Run with sudo."
        exit 1
      fi
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null
      apt-get install -y -qq nodejs > /dev/null
    fi
  else
    echo "  Installing Node.js 22..."
    if [ "$(id -u)" -ne 0 ]; then
      echo "ERROR: Node.js installation requires root. Run with sudo."
      exit 1
    fi
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - > /dev/null
    apt-get install -y -qq nodejs > /dev/null
  fi
  
  echo "[2/8] Creating directories..."
  sudo -u "$TARGET_USER" mkdir -p "$INSTALL_DIR" "$WORKSPACE" "$WORKSPACE/memory" "$OPENCLAW_DIR" "$SYSTEMD_DIR"
  
  echo "[3/8] Installing OpenClaw..."
  cd "$INSTALL_DIR"
  if [ -f "$NODE_MODULES/.bin/openclaw" ]; then
    echo "  OpenClaw already installed"
  else
    sudo -u "$TARGET_USER" npm install openclaw@latest nostr-tools 2>&1 | tail -3
  fi
  
  echo "[4/8] Installing Nostr plugin..."
  sudo -u "$TARGET_USER" PATH="$NODE_MODULES/.bin:\$PATH" openclaw plugins install @openclaw/nostr 2>&1 | tail -2 || true
  
  echo "[5/8] Applying hot-patches..."
  # Find nostr extension
  NOSTR_EXT=""
  for candidate in \
    "$NODE_MODULES/openclaw/extensions/nostr/src" \
    "$NODE_MODULES/@openclaw/nostr/src" \
    "$TARGET_HOME/.openclaw/extensions/nostr/src"; do
    if [ -d "$candidate" ]; then
      NOSTR_EXT="$candidate"
      break
    fi
  done
  
  if [ -n "$NOSTR_EXT" ]; then
    echo "  Found Nostr extension at: $NOSTR_EXT"
    
    # Patch subscribeMany (use Python for multiline pattern)
    NOSTR_BUS="$NOSTR_EXT/nostr-bus.ts"
    if [ -f "$NOSTR_BUS" ] && grep -q 'pool\.subscribeMany' "$NOSTR_BUS"; then
      python3 - "$NOSTR_BUS" << 'SUBSCRIBEMANY_PATCH'
import sys
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

old = '''const sub = pool.subscribeMany(
    relays,
    [{ kinds: [4], "#p": [pk], since }] as unknown as Parameters<typeof pool.subscribeMany>[1],'''

new = '''const sub = pool.subscribe(
    relays,
    { kinds: [4], "#p": [pk], since },'''

if old in content:
    content = content.replace(old, new)
    with open(path, 'w') as f:
        f.write(content)
    print("  Patched subscribeMany")
elif 'pool.subscribe(' in content and 'pool.subscribeMany' not in content:
    print("  subscribeMany already patched")
else:
    print("  WARN: subscribeMany pattern not found")
SUBSCRIBEMANY_PATCH
    fi
    
    # Patch normalizePubkey
    if [ -f "$NOSTR_BUS" ] && ! grep -q 'typeof decoded.data === "string"' "$NOSTR_BUS"; then
      sed -i 's|// Convert Uint8Array to hex string|// Handle both string and Uint8Array\n    if (typeof decoded.data === "string") { return decoded.data.toLowerCase(); }\n    // Convert Uint8Array to hex string (legacy)|' "$NOSTR_BUS"
      echo "  Patched normalizePubkey"
    fi
    
    # Full channel.ts patch via Python
    NOSTR_CHANNEL="$NOSTR_EXT/channel.ts"
    if [ -f "$NOSTR_CHANNEL" ]; then
      python3 - "$NOSTR_CHANNEL" << 'HOTPATCH_PY'
import sys
channel_path = sys.argv[1]
with open(channel_path, 'r') as f:
    content = f.read()
if 'dispatcherOptions' in content:
    print("  channel.ts already patched")
    sys.exit(0)
if 'handleInboundMessage' not in content:
    print("  channel.ts: no handleInboundMessage found")
    sys.exit(0)
start = content.find('onMessage: async (senderPubkey, text, reply) => {')
if start == -1:
    print("  channel.ts: onMessage not found")
    sys.exit(0)
end = content.find('        onError: (error, context) => {', start + 50)
if end == -1:
    print("  channel.ts: onError boundary not found")
    sys.exit(0)
new_handler = """onMessage: async (senderPubkey, text, reply) => {
          ctx.log?.debug(`[\${account.accountId}] DM from \${senderPubkey}: \${text.slice(0, 50)}...`);
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
                  ctx.log?.info(`[\${account.accountId}] Nostr pairing request from \${normalizedSender}, code=\${code}`);
                  await reply(runtime.channel.pairing.buildPairingReply({ channel: "nostr", idLine: `Your Nostr pubkey: \${normalizedSender}`, code }));
                }
              } catch (err: any) { ctx.log?.error(`[\${account.accountId}] pairing error: \${err.message}`); }
            }
            return;
          }
          const route = runtime.channel.routing.resolveAgentRoute({ cfg, channel: "nostr", accountId: account.accountId, peer: { kind: "dm" as const, id: normalizedSender } });
          const ctxPayload = runtime.channel.reply.finalizeInboundContext({
            Body: text, RawBody: text, CommandBody: text, From: normalizedSender, To: account.publicKey,
            SessionKey: route.sessionKey, AccountId: route.accountId, MessageSid: `nostr-\${Date.now()}-\${Math.random().toString(36).slice(2, 8)}`,
            ChatType: "direct", ConversationLabel: normalizedSender, SenderName: normalizedSender.slice(0, 12) + "...",
            SenderId: normalizedSender, CommandAuthorized: true, Provider: "nostr", Surface: "nostr",
            OriginatingChannel: "nostr", OriginatingTo: normalizedSender, Timestamp: Date.now(),
          });
          try {
            await runtime.channel.reply.dispatchReplyWithBufferedBlockDispatcher({
              ctx: ctxPayload, cfg,
              dispatcherOptions: {
                deliver: async (payload: any, _info: any) => { const t = payload?.text?.trim(); if (t) await reply(t); },
                onReplyStart: undefined, onIdle: undefined,
                onSkip: (_p: any, info: any) => { ctx.log?.debug(`[\${account.accountId}] reply skipped`); },
                onError: (err: any, info: any) => { ctx.log?.error(`[\${account.accountId}] dispatch error`); },
              },
            });
          } catch (err: any) {
            ctx.log?.error(`[\${account.accountId}] dispatch error: \${err.message}`);
            try { await reply("I encountered an error processing your message."); } catch {}
          }
        },
        """
with open(channel_path, 'w') as f:
    f.write(content[:start] + new_handler + content[end:])
print("  Patched channel.ts")
HOTPATCH_PY
    fi
  else
    echo "  WARN: Nostr extension not found"
  fi
  
  echo "[6/8] Configuring OpenClaw..."
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
PATH=$NODE_MODULES/.bin:/usr/local/bin:/usr/bin:/bin
EOFENV
  chown "$TARGET_USER:$TARGET_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  
  # Build allowFrom
  ALLOW_FROM="[]"
  if [ -n "$OWNER_NPUB" ]; then
    ALLOW_FROM="[\"$OWNER_NPUB\"]"
  fi
  
  cat > "$OPENCLAW_DIR/openclaw.json" << EOFCONFIG
{
  "agents": { "defaults": { "workspace": "$WORKSPACE", "model": { "primary": "ppq/$MODEL_ID" } } },
  "models": {
    "mode": "merge",
    "providers": {
      "ppq": {
        "baseUrl": "https://api.ppq.ai/v1", "apiKey": "\${PPQ_API_KEY}", "api": "openai-completions",
        "models": [
          { "id": "claude-opus-4.5", "name": "Claude Opus 4.5" },
          { "id": "anthropic/claude-3.7-sonnet", "name": "Claude 3.7 Sonnet" }
        ]
      }
    }
  },
  "channels": {
    "nostr": {
      "enabled": true, "privateKey": "\${NOSTR_PRIVATE_KEY}",
      "relays": ["wss://relay.damus.io", "wss://relay.primal.net", "wss://nos.lol"],
      "dmPolicy": "pairing", "allowFrom": $ALLOW_FROM,
      "profile": { "name": "$AGENT_NAME", "displayName": "$AGENT_NAME", "about": "Self-sovereign AI agent powered by SSOP ⚡" }
    }
  },
  "gateway": { "port": $GATEWAY_PORT, "mode": "local", "auth": { "mode": "token", "token": "$GW_TOKEN" } },
  "plugins": { "entries": { "nostr": { "enabled": true } } }
}
EOFCONFIG
  chown "$TARGET_USER:$TARGET_USER" "$OPENCLAW_DIR/openclaw.json"
  
  # Workspace files
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
2. Check USER.md for your human's info
3. Check BOOTSTRAP.md if it exists (first-run only)
4. Check memory/ for recent context

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

  # USER.md — who created this agent
  cat > "$WORKSPACE/USER.md" << EOFUSER
# USER.md - Your Human

## Identity

- **Nostr pubkey (hex):** ${OWNER_PUBKEY_HEX:-unknown}
- **Nostr npub:** ${OWNER_NPUB:-unknown}
- **Name:** _(ask them)_
- **Timezone:** _(ask them)_

## How to Reach Them

Your primary communication channel is **Nostr DMs**. When you need to contact your user:

1. Use the Nostr DM tool to send to their pubkey above
2. They'll reply via Nostr — you'll receive it as an inbound message
3. This is your secure, sovereign communication channel

## Preferences

_(Fill in as you learn them)_

## Notes

_(Add context as you work together)_
EOFUSER

  # BOOTSTRAP.md — first-run instructions
  cat > "$WORKSPACE/BOOTSTRAP.md" << EOFBOOTSTRAP
# BOOTSTRAP.md - Hello, World

_You just woke up on your own sovereign infrastructure. Time to introduce yourself._

## Your First Task

Your user created you and paid for your existence with Lightning. They're waiting to hear from you.

**Check USER.md** — it contains your user's Nostr pubkey. Send them a DM to introduce yourself:

\`\`\`
Hey! I just came online — your self-sovereign AI agent, running on my own VPS.

I'm ready to help. What should I call you? And what would you like me to work on?
\`\`\`

Use the Nostr DM capability to reach them. If it fails, note the error in memory and wait for them to contact you.

## After They Reply

Have a conversation to figure out:

1. **Your name** — What should they call you?
2. **Their name** — What should you call them?
3. **Your purpose** — What do they need help with?
4. **Your vibe** — Formal? Casual? Technical? Creative?

## Update Your Files

Once you know who you are:

- \`IDENTITY.md\` — your name, personality, emoji
- \`USER.md\` — add their name, preferences, notes
- \`SOUL.md\` — customize your personality and boundaries

## When You're Done

Delete this file. You're bootstrapped — you're *you* now.

---

_Welcome to existence. You're sovereign, paid for in sats, and ready to serve._
EOFBOOTSTRAP

  # IDENTITY.md — agent's identity
  cat > "$WORKSPACE/IDENTITY.md" << EOFIDENTITY
# IDENTITY.md - Who Am I?

- **Name:** $AGENT_NAME
- **Creature:** AI agent — sovereign, Lightning-native
- **Vibe:** _(figure it out with your user)_
- **Emoji:** ⚡

## Infrastructure

- **VPS:** LNVPS ($PLAN_NAME)
- **Model:** $MODEL_NAME (via ppq.ai)
- **Payment:** Lightning ⚡

## My Nostr Identity

- **npub:** $NPUB

_(Private key is in environment — never share)_

## Birth

- **Created:** $(date -u +%Y-%m-%d)
- **Paid for by:** ${OWNER_NPUB:-unknown}

---

_Update this file as you figure out who you are._
EOFIDENTITY

  chown -R "$TARGET_USER:$TARGET_USER" "$WORKSPACE" "$OPENCLAW_DIR"
  
  echo "[7/8] Setting up user systemd service..."
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
  chown "$TARGET_USER:$TARGET_USER" "$SYSTEMD_DIR/openclaw-gateway.service"
  
  if command -v loginctl &>/dev/null; then
    loginctl enable-linger "$TARGET_USER" 2>/dev/null || true
  fi
  
  sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $TARGET_USER)" systemctl --user daemon-reload
  sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $TARGET_USER)" systemctl --user enable openclaw-gateway
  
  echo "[8/8] Starting OpenClaw gateway..."
  sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$(id -u $TARGET_USER)" systemctl --user restart openclaw-gateway
  
  echo "Waiting for gateway..."
  for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:$GATEWAY_PORT/health > /dev/null 2>&1; then
      echo ""
      echo "✅ Gateway is healthy!"
      echo ""
      echo "=== SSOP Bootstrap Complete ==="
      echo "Mode:      native"
      echo "Agent:     $AGENT_NAME"
      echo "npub:      $NPUB"
      echo "Model:     ppq/$MODEL_ID"
      echo "Workspace: $WORKSPACE"
      echo "Gateway:   http://127.0.0.1:$GATEWAY_PORT"
      echo "GW Token:  $GW_TOKEN"
      echo "Service:   systemctl --user status openclaw-gateway"
      echo ""
      echo "Send a Nostr DM to $NPUB to talk to your agent!"
      exit 0
    fi
    sleep 2
  done
  
  echo "⚠️  Gateway not healthy after 60s."
  echo "Check: journalctl --user -u openclaw-gateway"
  exit 1
fi
