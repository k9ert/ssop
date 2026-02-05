FROM node:22-slim

# System deps: python3 for hot-patches, curl for health checks, openssl for token gen
RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 curl openssl && \
    rm -rf /var/lib/apt/lists/*

# Install openclaw globally
RUN npm install -g openclaw@latest 2>&1 | tail -5

# Install Nostr channel plugin
RUN openclaw plugins install @openclaw/nostr 2>&1 | tail -3 || true

# Install nostr-tools globally (openclaw#8670 workaround)
RUN npm install -g nostr-tools

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
