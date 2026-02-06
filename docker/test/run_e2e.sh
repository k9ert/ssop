#!/usr/bin/env bash
# SSOP Agent E2E Test
# Usage: ./run_e2e.sh [image_tag] [ppq_api_key]
set -euo pipefail

IMAGE="${1:-ssop-agent:local}"
PPQ_KEY="${2:-${PPQ_API_KEY:-}}"
WORKSPACE="/tmp/ssop-e2e-workspace"
CONTAINER="ssop-e2e-test"
TIMEOUT_HEALTH=90
TIMEOUT_DM=120
RELAY="wss://relay.damus.io"

echo "=== SSOP E2E Test ==="
echo "Image: $IMAGE"
echo ""

# Check deps
if [ -z "$PPQ_KEY" ]; then
  echo "ERROR: PPQ_API_KEY required (pass as arg or env var)"
  exit 1
fi

command -v jq >/dev/null || { echo "ERROR: jq required"; exit 1; }
command -v node >/dev/null || { echo "ERROR: node required"; exit 1; }

# Cleanup from previous runs
echo "[1/6] Cleanup..."
docker stop "$CONTAINER" 2>/dev/null || true
docker rm "$CONTAINER" 2>/dev/null || true
rm -rf "$WORKSPACE"
mkdir -p "$WORKSPACE/memory"

# Generate keys
echo "[2/6] Generating Nostr keypairs..."
KEYS=$(node "$(dirname "$0")/generate_keys.js")
AGENT_NSEC=$(echo "$KEYS" | jq -r .agentNsec)
AGENT_NPUB=$(echo "$KEYS" | jq -r .agentNpub)
TESTER_NSEC=$(echo "$KEYS" | jq -r .testerNsec)
TESTER_NPUB=$(echo "$KEYS" | jq -r .testerNpub)
echo "  Agent:  $AGENT_NPUB"
echo "  Tester: $TESTER_NPUB"

# Start container
echo "[3/6] Starting container..."
docker run -d --name "$CONTAINER" \
  -e NOSTR_NSEC="$AGENT_NSEC" \
  -e NOSTR_NPUB="$AGENT_NPUB" \
  -e PPQ_API_KEY="$PPQ_KEY" \
  -e MODEL_ID="qwen/qwen3-30b-a3b" \
  -e AGENT_NAME="E2E-Test-Agent" \
  -e OWNER_NPUB="$TESTER_NPUB" \
  -e DM_POLICY="open" \
  -v "$WORKSPACE:/root/agent" \
  -p 18789:18789 \
  "$IMAGE"

# Wait for health
echo "[4/6] Waiting for gateway (max ${TIMEOUT_HEALTH}s)..."
for i in $(seq 1 $TIMEOUT_HEALTH); do
  if curl -sf http://127.0.0.1:18789/ > /dev/null 2>&1; then
    echo "  ✅ Gateway healthy after ${i}s"
    break
  fi
  if [ $i -eq $TIMEOUT_HEALTH ]; then
    echo "  ❌ Gateway not responding after ${TIMEOUT_HEALTH}s"
    echo "=== Container logs ==="
    docker logs "$CONTAINER" 2>&1 | tail -30
    docker rm -f "$CONTAINER" 2>/dev/null || true
    exit 1
  fi
  sleep 1
done

# Send DM
echo "[5/6] Sending test DM..."
export TEST_MESSAGE="Reply with exactly: PONG"
export RELAY_URL="$RELAY"
node "$(dirname "$0")/send_dm.js" "$AGENT_NPUB" "$TESTER_NSEC" "$TIMEOUT_DM"

# Verify workspace
echo ""
echo "[6/6] Verifying workspace..."
echo "=== Workspace contents ==="
ls -la "$WORKSPACE/"
if [ -f "$WORKSPACE/MEMORY.md" ]; then
  echo ""
  echo "=== MEMORY.md ==="
  cat "$WORKSPACE/MEMORY.md"
fi

# Cleanup
echo ""
echo "=== Cleanup ==="
docker stop "$CONTAINER" 2>/dev/null || true
docker rm "$CONTAINER" 2>/dev/null || true

echo ""
echo "✅ E2E TEST PASSED"
