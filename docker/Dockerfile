FROM node:22-slim

# System deps: python3 for hot-patches, curl for health checks, openssl for token gen,
# git + ca-certificates for npm deps that reference git repos
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 curl openssl git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Force git to use HTTPS (some npm deps reference git+ssh which fails without SSH keys)
RUN git config --global url."https://github.com/".insteadOf git@github.com: && \
    git config --global url."https://github.com/".insteadOf ssh://git@github.com/

# Install openclaw + nostr-tools globally
# Pin versions — dependabot updates docker/package.json, Dockerfile reads from it
COPY package.json /tmp/versions.json
RUN OPENCLAW_V=$(node -p "require('/tmp/versions.json').dependencies.openclaw") && \
    NOSTR_V=$(node -p "require('/tmp/versions.json').dependencies['nostr-tools']") && \
    echo "Installing openclaw@$OPENCLAW_V nostr-tools@$NOSTR_V" && \
    npm install -g "openclaw@$OPENCLAW_V" "nostr-tools@$NOSTR_V" 2>&1 | tail -10 && \
    rm /tmp/versions.json

# Verify openclaw is installed and find its path
RUN which openclaw && openclaw --version

# Install Nostr channel plugin
RUN openclaw plugins install @openclaw/nostr 2>&1 | tail -5 || true

# Ensure global npm bin is on PATH (node:22-slim uses /usr/local/bin)
ENV PATH="/usr/local/bin:${PATH}"

# Apply hot-patches at build time (baked into image)
COPY patches/ /tmp/patches/
RUN python3 /tmp/patches/apply.py && rm -rf /tmp/patches

# Default workspace skeleton (will be overlaid by bind mount)
COPY workspace/ /opt/ssop/workspace-defaults/

# Entrypoint generates config from env vars and starts gateway
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 18789

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -sf http://127.0.0.1:18789/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
