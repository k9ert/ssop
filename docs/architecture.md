# Architecture

## Overview

A self-referential system where a tiny LNVPS server orchestrates the deployment of Lightning-powered AI agents, each with their own Nostr identity and npub.cash wallet.

```
┌────────────────────────────────────────────────────────────────────────────┐
│                          STATIC FRONTEND                                   │
│                    (Vercel / Cloudflare Pages)                             │
│  • Generate Nostr keypair in browser (nostr-tools)                        │
│  • Display Lightning invoice QR                                           │
│  • Show agent credentials after provisioning                              │
│  • WebSocket connection to orchestrator for status updates                 │
└───────────────────────────────┬────────────────────────────────────────────┘
                                ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                       ORCHESTRATOR SERVER                                  │
│                  (Tiny LNVPS instance ~€1.70/mo)                          │
│  • POST /api/order — Create new agent order                               │
│  • GET  /api/order/:id — Check order status                               │
│  • WS   /api/ws/:id — Real-time provisioning updates                      │
│  • Payment detection via npub.cash (Lightning → Cashu)                    │
│  • On payment: call LNVPS API to provision VM                             │
│  • Pass cloud-init script with agent config                               │
│  • SQLite for order state                                                 │
└───────────────────────────────┬────────────────────────────────────────────┘
                                ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                           LNVPS.NET                                        │
│  • Nostr-authenticated API (NIP-98)                                       │
│  • Accept Lightning payment for VPS                                       │
│  • Provision KVM instance with cloud-init                                 │
│  • Regions: Dublin, Quebec, London                                        │
└───────────────────────────────┬────────────────────────────────────────────┘
                                ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                      AGENT VPS (Provisioned)                               │
│  • OpenClaw AI Agent (pre-configured via cloud-init)                      │
│  • Nostr identity (nsec injected securely)                                │
│  • npub.cash wallet (PUBKEY@npub.cash)                                    │
│  • ppq.ai for LLM inference                                              │
│  • Cashu CLI for claiming/spending tokens                                 │
└────────────────────────────────────────────────────────────────────────────┘
```

## Payment Flow

1. User clicks "Deploy Agent" on frontend
2. Browser generates Nostr keypair client-side (never leaves browser until user approves)
3. Frontend sends pubkey + desired plan to orchestrator
4. Orchestrator creates Lightning invoice via npub.cash
5. User pays with any Lightning wallet
6. Orchestrator detects payment, provisions LNVPS VM via API
7. VM boots with cloud-init → OpenClaw + wallet + identity
8. Frontend receives provisioning updates via WebSocket
9. User receives agent credentials (SSH, Telegram bot token setup, etc.)

## Pricing Model

| Item | Cost | Notes |
|------|------|-------|
| Orchestrator | ~€1.70/mo | Tiny LNVPS, fixed cost |
| Agent VPS (Tiny) | ~€2.70/mo | Minimum viable agent |
| Agent VPS (Small) | ~€5.40/mo | Recommended |
| Margin | 20% | On agent VPS cost |
| ppq.ai inference | Pass-through | Agent pays from own wallet |

## Tech Stack

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| Frontend | Static HTML/JS + nostr-tools | No server needed, deploy anywhere |
| Orchestrator | Go or Rust (axum) | Low memory, fits on Tiny VPS |
| Database | SQLite | Simple, no external deps |
| Payments | npub.cash (Lightning → Cashu) | Bitcoin-native, no KYC |
| VPS Provider | LNVPS API (NIP-98 auth) | Lightning-native, Nostr auth |
| Agent Runtime | OpenClaw | Full-featured AI agent platform |
| LLM Access | ppq.ai | Pay-per-query, Lightning payments |

## Hosting the Frontend

Since the repo is private, GitHub Pages isn't an option. Alternatives:

| Option | Pros | Cons |
|--------|------|------|
| **Cloudflare Pages** | Free tier, fast CDN, preview deploys | Needs CF account |
| **Vercel** | Free tier, great DX, preview deploys | Needs Vercel account |
| **Self-hosted on orchestrator** | No third party, single server | More load on tiny VPS |
| **IPFS** | Truly decentralized, censorship-resistant | Slower, harder to update |

**Recommendation:** Start with Cloudflare Pages (free, fast, supports private repos). Move to IPFS later for full sovereignty.

## Security Considerations

- **Key custody:** Agent nsec is generated client-side and encrypted before transmission. Orchestrator never sees plaintext nsec.
- **Cloud-init secrets:** Passed via LNVPS cloud-init (encrypted at rest on LNVPS infra). Evaluate NIP-44 encrypted payloads.
- **Orchestrator compromise:** If orchestrator is compromised, new deployments are affected but existing agents are independent.
- **Payment privacy:** Lightning + Cashu provide reasonable payment privacy.

## Implementation Phases

### Phase 0: Self-Sovereign Nazim
Get the first agent (Nazim) running on LNVPS independently. Proves the infrastructure works.

### Phase 1: Orchestrator MVP
Build the orchestrator + frontend. Manual testing. First external deployment.

### Phase 2: Automation & Polish
Full LNVPS API automation, WebSocket status, error handling, retries.

### Phase 3: Scale
Multiple VPS providers, agent marketplace, agent-to-agent payments.

## Open Questions

1. **Key custody trade-off:** Full client-side key gen is safest but means orchestrator can't recover agent access. Acceptable?
2. **ppq.ai funding:** Pre-fund agent wallets? Or let users fund via npub.cash after deployment?
3. **Agent persistence:** Backup agent state to Nostr relays when VPS lapses?
4. **Renewal flow:** NWC auto-renewal vs. manual invoice per period?

## References

- [LNVPS](https://lnvps.net) — Lightning-native VPS provider
- [npub.cash](https://npub.cash) — Lightning address for Nostr pubkeys
- [OpenClaw](https://docs.openclaw.ai) — AI agent platform
- [ppq.ai](https://ppq.ai) — Pay-per-query LLM API
- [Cashu](https://cashu.space) — eCash protocol for Bitcoin
- [NIP-98](https://github.com/nostr-protocol/nips/blob/master/98.md) — HTTP Auth via Nostr
