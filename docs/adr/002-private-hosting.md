# ADR-002: Frontend Hosting (Private Repo)

## Status
Proposed

## Context
The repo is private on GitHub. GitHub Pages requires public repos (on free plan) or a paid plan. We need an alternative for hosting the static frontend.

## Options Considered
1. **Cloudflare Pages** — Free tier, connects to private GitHub repos, global CDN, preview deploys
2. **Vercel** — Free tier, connects to private repos, preview deploys, good DX
3. **Self-hosted on orchestrator** — Serve static files from the same tiny VPS
4. **IPFS** — Decentralized, censorship-resistant, no account needed

## Decision
Start with **Cloudflare Pages** for development. Evaluate IPFS for production when we're closer to launch.

## Rationale
- Free tier is generous (500 builds/month, unlimited bandwidth)
- Native private repo support
- Preview deploys for testing
- Cloudflare CDN is fast globally
- IPFS is the long-term goal (sovereignty) but adds complexity we don't need yet

## Consequences
- Need a Cloudflare account
- Frontend deploy is one `git push` away
- Can migrate to IPFS later without changing the frontend code (it's all static)
