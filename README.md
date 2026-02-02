# SSOP — Self Sovereign OpenClaw Platform

One-click deploy of self-sovereign AI agents on Lightning-paid VPS infrastructure.

**Stack:** Nostr identity · Lightning payments · LNVPS hosting · OpenClaw agents · ppq.ai inference

## What

Deploy your own AI agent with a single Lightning payment. No KYC, no credit cards, no cloud accounts. Just sats.

Each agent gets:
- 🔑 Nostr keypair (generated client-side)
- 💰 npub.cash Lightning wallet
- 🖥️ Dedicated KVM instance on LNVPS
- 🤖 Pre-configured OpenClaw gateway
- 🧠 LLM inference via ppq.ai

## Architecture

```
Browser (static frontend)
    ↓ generate keypair, pay invoice
Orchestrator (tiny LNVPS instance)
    ↓ provision via LNVPS API
Agent VPS (OpenClaw + Nostr + Cashu + ppq.ai)
```

See [docs/architecture.md](docs/architecture.md) for the full design.

## Repo Structure

```
ssop/
├── docs/           # Architecture, design docs, ADRs
├── frontend/       # Static SPA (nostr-tools, QR codes, WebSocket status)
├── orchestrator/   # API server (order → payment → provision)
├── cloud-init/     # VM bootstrap templates
├── scripts/        # Utility scripts (LNVPS client, testing)
└── README.md
```

## Status

**Phase 0:** Getting the first agent (Nazim) self-sovereign on LNVPS.

## License

MIT
