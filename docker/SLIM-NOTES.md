# Docker Slimming Notes

## Baseline (2026-02-06)
- Image: `ssop-agent:local`
- Size: **2.16GB**
- Base: `node:22-slim` (Debian bookworm)
- E2E test: PASS (PONG in 8.6s)

## Phase 1: Multi-stage Build (commit 5b04b6d)
- Image: `ssop-agent:slim`
- Size: **1.38GB** (-780MB, -36%)
- Changes:
  - Stage 1 (builder): Install python3, git, openclaw, apply patches
  - Stage 2 (runtime): Only curl, openssl, ca-certificates
  - COPY node_modules from builder, create symlink for openclaw binary
  - Removed python3, git from runtime image
- E2E test: PASS (PONG in 10s, gateway up in 61s)

## Phase 2: Prune llama-cpp (commit 7f1e3e3)
- Image: `ssop-agent:pruned`
- Size: **627MB** (-753MB from Phase 1, **-71% from baseline**)
- Changes:
  - Remove `@node-llama-cpp` (677MB) - local LLM inference not needed (we use ppq API)
  - Remove `node-llama-cpp` (34MB) - related bindings
  - Remove `docs/` (13MB) - not needed at runtime
  - Prune happens in builder stage BEFORE COPY (important for Docker layer efficiency)
- E2E test: Container starts, gateway healthy in ~60s
- Note: Can't remove channel SDKs (Slack, WhatsApp, etc.) - loader imports them even if unused

## Summary
| Phase | Size | Δ from baseline |
|-------|------|----------------|
| Baseline | 2.16GB | - |
| Phase 1 (multi-stage) | 1.38GB | -36% |
| **Phase 2 (prune llama)** | **627MB** | **-71%** |

## Future Optimizations
1. Alpine base (smaller, but may have glibc issues with native deps)
2. Distroless Node.js (smaller, no shell - harder to debug)
3. More aggressive prune (would need OpenClaw changes to lazy-load dependencies)
