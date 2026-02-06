# Docker Image Slimming Notes

## Baseline (2026-02-06)
- **Image:** ssop-agent:local
- **Size:** 2.16GB
- **Base:** node:22-slim (Debian)
- **CI:** Green (E2E test passing)

### Layer breakdown:
| Size | Layer |
|------|-------|
| 1.79GB | npm install openclaw, nostr-tools, zod |
| 145MB | Node.js 22 base |
| 131MB | apt packages (python3, git, curl, openssl, ca-certs) |
| 11.5MB | openclaw --version (doctor?) |
| 35.9kB | patches |

---

## Step 1: Alpine base
- **Branch:** slim-docker
- **Change:** node:22-slim → node:22-alpine
- **Before:** 2.16GB
- **After:** TBD
- **Delta:** TBD
- **Test result:** TBD

