#!/usr/bin/env bash
# Test harness for bootstrap.sh
set -euo pipefail

TEST_DIR=$(mktemp -d)
PASSED=0
FAILED=0

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

pass() { echo "  ✅ $1"; ((PASSED++)) || true; }
fail() { echo "  ❌ $1"; ((FAILED++)) || true; }

test_eq() {
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3 (got '$1', expected '$2')"
  fi
}

test_contains() {
  if [[ "$1" == *"$2"* ]]; then
    pass "$3"
  else
    fail "$3 (missing '$2')"
  fi
}

echo "=== Bootstrap.sh Tests ==="
echo ""

# --- Test 1: Config parsing ---
echo "[1] Config parsing"
cat > "$TEST_DIR/config.json" << 'EOF'
{
  "nsec": "nsec1test123",
  "npub": "npub1test456",
  "model_id": "qwen/qwen3-30b-a3b",
  "ppq_api_key": "sk-testkey",
  "agent_name": "TestAgent",
  "owner_npub": "npub1owner"
}
EOF

NSEC=$(python3 -c "import json; print(json.load(open('$TEST_DIR/config.json'))['nsec'])")
test_eq "$NSEC" "nsec1test123" "nsec parsed"

AGENT_NAME=$(python3 -c "import json; print(json.load(open('$TEST_DIR/config.json')).get('agent_name', 'Agent'))")
test_eq "$AGENT_NAME" "TestAgent" "agent_name parsed"

OWNER=$(python3 -c "import json; print(json.load(open('$TEST_DIR/config.json')).get('owner_npub', ''))")
test_eq "$OWNER" "npub1owner" "owner_npub parsed"

# --- Test 2: Mode auto-detection logic ---
echo ""
echo "[2] Mode auto-detection"

auto_detect_mode() {
  local has_docker="$1" has_node="$2" node_version="$3"
  if [ "$has_docker" = "true" ]; then
    echo "container"
  elif [ "$has_node" = "true" ] && [ "$node_version" -ge 22 ]; then
    echo "native"
  else
    echo "docker"
  fi
}

test_eq "$(auto_detect_mode true false 0)" "container" "docker present → container"
test_eq "$(auto_detect_mode false true 22)" "native" "node 22 present → native"
test_eq "$(auto_detect_mode false true 18)" "docker" "node 18 (old) → docker"
test_eq "$(auto_detect_mode false false 0)" "docker" "empty machine → docker"

# --- Test 3: Argument parsing ---
echo ""
echo "[3] Argument parsing"

parse_args() {
  local mode="" config="" tag="latest"
  for arg in "$@"; do
    case $arg in
      --mode=*) mode="${arg#*=}" ;;
      --tag=*) tag="${arg#*=}" ;;
      *) [ -z "$config" ] && config="$arg" ;;
    esac
  done
  echo "mode=$mode config=$config tag=$tag"
}

result=$(parse_args config.json --mode=native --tag=v1.0)
test_contains "$result" "mode=native" "--mode parsed"
test_contains "$result" "config=config.json" "config file parsed"
test_contains "$result" "tag=v1.0" "--tag parsed"

# --- Test 4: Systemd unit generation (container) ---
echo ""
echo "[4] Systemd unit (container mode)"

generate_container_unit() {
  local env_file="$1" image="$2" workspace="$3"
  cat << EOFSVC
[Unit]
Description=SSOP Agent (Docker)
After=network.target docker.service

[Service]
Type=simple
EnvironmentFile=$env_file
ExecStart=/usr/bin/docker run --rm --name ssop-agent -v $workspace:/root/agent $image
Restart=always

[Install]
WantedBy=default.target
EOFSVC
}

unit=$(generate_container_unit "/home/test/.openclaw/env" "ghcr.io/k9ert/ssop-agent:latest" "/home/test/agent")
test_contains "$unit" "EnvironmentFile=/home/test/.openclaw/env" "env file path"
test_contains "$unit" "docker run" "docker run cmd"
test_contains "$unit" "-v /home/test/agent:/root/agent" "volume mount"
test_contains "$unit" "ghcr.io/k9ert/ssop-agent:latest" "image name"

# --- Test 5: Systemd unit generation (native) ---
echo ""
echo "[5] Systemd unit (native mode)"

generate_native_unit() {
  local env_file="$1" openclaw_bin="$2" workspace="$3"
  cat << EOFSVC
[Unit]
Description=OpenClaw Gateway
After=network.target

[Service]
Type=simple
WorkingDirectory=$workspace
ExecStart=$openclaw_bin gateway
EnvironmentFile=$env_file
Restart=always

[Install]
WantedBy=default.target
EOFSVC
}

unit=$(generate_native_unit "/home/test/.openclaw/env" "/home/test/openclaw/node_modules/.bin/openclaw" "/home/test/agent")
test_contains "$unit" "openclaw gateway" "openclaw gateway cmd"
test_contains "$unit" "WorkingDirectory=/home/test/agent" "workspace dir"
test_contains "$unit" "Restart=always" "restart policy"

# --- Test 6: Environment file generation ---
echo ""
echo "[6] Environment file generation"

generate_env_container() {
  local nsec="$1" npub="$2" ppq_key="$3" model="$4" name="$5"
  cat << EOF
NOSTR_NSEC=$nsec
NOSTR_NPUB=$npub
PPQ_API_KEY=$ppq_key
MODEL_ID=$model
AGENT_NAME=$name
EOF
}

generate_env_native() {
  local nsec="$1" ppq_key="$2"
  cat << EOF
NOSTR_PRIVATE_KEY=$nsec
PPQ_API_KEY=$ppq_key
NODE_OPTIONS=--dns-result-order=ipv4first
EOF
}

env_c=$(generate_env_container "nsec1abc" "npub1xyz" "sk-123" "qwen/test" "Bot")
test_contains "$env_c" "NOSTR_NSEC=nsec1abc" "container: NOSTR_NSEC"
test_contains "$env_c" "NOSTR_NPUB=npub1xyz" "container: NOSTR_NPUB"
test_contains "$env_c" "MODEL_ID=qwen/test" "container: MODEL_ID"

env_n=$(generate_env_native "nsec1abc" "sk-123")
test_contains "$env_n" "NOSTR_PRIVATE_KEY=nsec1abc" "native: NOSTR_PRIVATE_KEY"
test_contains "$env_n" "NODE_OPTIONS=--dns-result-order=ipv4first" "native: NODE_OPTIONS"

# --- Summary ---
echo ""
echo "==================="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "==================="

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
