# Docker Slimming Notes

## Baseline (2026-02-06)
- Image: `ssop-agent:local`
- Size: **2.16GB**
- Base: `node:22-slim` (Debian bookworm)
- E2E test: PASS (PONG in 8.6s)

## Multi-stage Build (commit 5b04b6d)
- Image: `ssop-agent:slim`
- Size: **1.38GB** (-780MB, -36%)
- Changes:
  - Stage 1 (builder): Install python3, git, openclaw, apply patches
  - Stage 2 (runtime): Only curl, openssl, ca-certificates
  - COPY node_modules from builder, create symlink for openclaw binary
  - Removed python3, git from runtime image
- E2E test: PASS (PONG in 10s, gateway up in 61s)

## Next Optimizations to Try
1. Prune node_modules (remove docs, tests, typescript sources)
2. Alpine base (smaller, but may have glibc compatibility issues)
3. Distroless Node.js (smaller, no shell)
4. npm prune --production (remove devDependencies)
