# Next Steps

## Immediate (Phase 0 — Self-Sovereign Nazim)

### 1. Complete LNVPS Authentication
The LNVPS API uses NIP-98 HTTP Auth (Nostr event kind 27235 in `Authorization` header). Our `scripts/lnvps.py` already implements this. Next:
- [ ] Pay the pending 12,576 sat invoice for 3 months Tiny VPS
- [ ] Upload SSH key via API
- [ ] Create VM on Tiny plan (Dublin region)
- [ ] Verify SSH access to the new VM

### 2. Build Cloud-Init Template
Create a cloud-init YAML that bootstraps a fresh LNVPS VM into a working OpenClaw agent:
- [ ] Install Node.js (v22 LTS)
- [ ] Install OpenClaw via npm
- [ ] Configure gateway (Telegram channel, ppq.ai model provider)
- [ ] Inject Nostr identity (nsec via cloud-init write_files)
- [ ] Set up systemd service for OpenClaw gateway
- [ ] Install essential skills

### 3. Test Agent Independence
- [ ] Deploy Nazim clone to LNVPS VM
- [ ] Verify Telegram communication works
- [ ] Run for 24h, check heartbeats and crons
- [ ] Confirm it survives independently of k9ert's VPS

## Near-Term (Phase 1 — Orchestrator MVP)

### 4. Research npub.cash Integration
- [ ] Understand LNURL-pay flow for npub.cash
- [ ] Test receiving Lightning payments to a npub.cash address
- [ ] Document payment notification mechanism

### 5. Choose Orchestrator Language
Decision between Go and Rust:
- **Go:** Faster to prototype, lighter binary, good enough performance
- **Rust:** Better memory safety, smaller binary, but slower iteration
- Leaning Go for MVP speed. Tiny VPS has 512MB RAM — both fit easily.

### 6. Build Orchestrator API
Minimal endpoints:
```
POST /api/order         — Create deployment order
GET  /api/order/:id     — Check order status
WS   /api/ws/:id        — Real-time status stream
GET  /api/plans          — Available VPS plans + pricing
```

### 7. Build Frontend
Static SPA with:
- Nostr keypair generation (nostr-tools in browser)
- Plan selection
- Lightning invoice QR display
- WebSocket status updates
- Credential delivery

### 8. Deploy Frontend
Connect private repo to Cloudflare Pages. Set up:
- Build command (if any bundler) or direct deploy
- Preview deploys for PRs
- Custom domain (ssop.xyz? sovereign.agent? TBD)

## Hosting Decision Summary

| Option | Works with Private Repo | Free Tier | Bitcoin-Native |
|--------|------------------------|-----------|----------------|
| GitHub Pages | ❌ (paid only) | Yes (public) | No |
| Cloudflare Pages | ✅ | Yes | No |
| Vercel | ✅ | Yes | No |
| Self-hosted (orchestrator) | ✅ | N/A | Yes |
| IPFS | ✅ | Yes | Yes |

**Plan:** Cloudflare Pages now → IPFS later for full sovereignty.
