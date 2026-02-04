#!/bin/bash
# SSOP Skills Installer
# Usage: curl -sL ssop.pages.dev/install.sh | bash
#
# Installs the ssop-core skill bundle (lightning, ppq, lnvps, heartbeat)
# into the current OpenClaw agent workspace.

set -e

SSOP_URL="${SSOP_URL:-https://ssop.pages.dev}"
SKILLS_DIR="${SKILLS_DIR:-./skills}"
SCRIPTS_DIR="${SCRIPTS_DIR:-./scripts}"

echo "🔧 SSOP Skills Installer"
echo "========================"
echo ""

# Detect workspace
if [ ! -f "AGENTS.md" ] && [ ! -f "SOUL.md" ]; then
    echo "⚠️  Warning: Not in an OpenClaw workspace (no AGENTS.md or SOUL.md found)"
    echo "   Creating directories anyway..."
fi

mkdir -p "$SKILLS_DIR" "$SCRIPTS_DIR"

# Fetch manifest
echo "📦 Fetching skill manifest..."
MANIFEST=$(curl -sL "$SSOP_URL/skills/manifest.json")
if [ -z "$MANIFEST" ]; then
    echo "❌ Failed to fetch manifest from $SSOP_URL/skills/manifest.json"
    exit 1
fi

# Get ssop-core bundle skills
SKILLS=$(echo "$MANIFEST" | python3 -c "import sys,json; print(' '.join(json.load(sys.stdin)['bundles']['ssop-core']))")
echo "   Skills to install: $SKILLS"
echo ""

# Install each skill
for skill in $SKILLS; do
    echo "📥 Installing $skill..."
    
    # Create skill directory
    mkdir -p "$SKILLS_DIR/$skill"
    
    # Download SKILL.md
    curl -sL "$SSOP_URL/skills/$skill/SKILL.md" -o "$SKILLS_DIR/$skill/SKILL.md"
    
    if [ -f "$SKILLS_DIR/$skill/SKILL.md" ]; then
        echo "   ✅ $skill/SKILL.md"
    else
        echo "   ❌ Failed to download $skill"
        continue
    fi
done

echo ""
echo "📜 Extracting scripts from skills..."

# Extract embedded scripts from SKILL.md files
for skill in $SKILLS; do
    SKILL_FILE="$SKILLS_DIR/$skill/SKILL.md"
    if [ -f "$SKILL_FILE" ]; then
        # Extract Python scripts between ```python and ```
        python3 << EOF
import re
with open("$SKILL_FILE", "r") as f:
    content = f.read()

# Find script filename and content
# Pattern: Install to \`scripts/NAME.py\`:\n\n\`\`\`python\n...CODE...\n\`\`\`
pattern = r'Install to \`scripts/([^`]+)\`:\s*\n+\`\`\`python\n(.*?)\n\`\`\`'
matches = re.findall(pattern, content, re.DOTALL)

for filename, code in matches:
    filepath = "$SCRIPTS_DIR/" + filename
    with open(filepath, "w") as f:
        f.write(code)
    print(f"   ✅ scripts/{filename}")
EOF
    fi
done

echo ""
echo "🔍 Checking environment variables..."

check_env() {
    if [ -z "${!1}" ]; then
        echo "   ⚠️  $1 not set"
    else
        echo "   ✅ $1"
    fi
}

check_env "BLINK_API_KEY"
check_env "BLINK_BTC_WALLET_ID"
check_env "PPQ_API_KEY"
check_env "NOSTR_NSEC"
check_env "VM_ID"
check_env "OWNER_NPUB"

echo ""
echo "✨ SSOP Skills Installation Complete!"
echo ""
echo "Installed to:"
echo "   Skills:  $SKILLS_DIR/"
echo "   Scripts: $SCRIPTS_DIR/"
echo ""
echo "Next steps:"
echo "1. Set any missing environment variables above"
echo "2. Add SSOP heartbeat check to your HEARTBEAT.md"
echo "3. Test: python3 scripts/ssop_heartbeat.py"
echo ""
