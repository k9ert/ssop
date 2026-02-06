# Multi-stage build for smaller image
# Stage 1: Build (install deps)
FROM node:22-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends python3 curl openssl git ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN git config --global url."https://github.com/".insteadOf git@github.com: && \
    git config --global url."https://github.com/".insteadOf ssh://git@github.com/

COPY package.json /tmp/versions.json
RUN OPENCLAW_V=$(node -p "require('/tmp/versions.json').dependencies.openclaw") && \
    NOSTR_V=$(node -p "require('/tmp/versions.json').dependencies['nostr-tools']") && \
    ZOD_V=$(node -p "require('/tmp/versions.json').dependencies.zod") && \
    echo "Installing openclaw@$OPENCLAW_V nostr-tools@$NOSTR_V zod@$ZOD_V" && \
    npm install -g "openclaw@$OPENCLAW_V" "nostr-tools@$NOSTR_V" "zod@$ZOD_V" && \
    rm /tmp/versions.json

# Apply hot-patches in builder
COPY patches/ /tmp/patches/
RUN python3 /tmp/patches/apply.py && rm -rf /tmp/patches

# Prune dev dependencies and caches
RUN npm cache clean --force && \
    rm -rf /root/.npm /root/.node-gyp /tmp/*

# Stage 2: Runtime (minimal)
FROM node:22-slim

# Only runtime deps
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl openssl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Copy openclaw from builder
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s /usr/local/lib/node_modules/openclaw/dist/entry.js /usr/local/bin/openclaw

# Verify
RUN openclaw --version

ENV PATH="/usr/local/bin:${PATH}"
ENV NODE_PATH="/usr/local/lib/node_modules"

# Workspace defaults
COPY workspace/ /opt/ssop/workspace-defaults/

# Entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 18789

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -sf http://127.0.0.1:18789/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
