---
name: ssop
version: 0.1.0
description: Deploy a self-sovereign AI agent on your own VPS. Pay with Lightning. No KYC. No cloud accounts.
homepage: https://ssop.pages.dev
metadata: {"category": "infrastructure", "api_base": "https://185-18-221-5.sslip.io:8443"}
---

# SSOP — Self Sovereign OpenClaw Platform

Deploy your own AI agent on dedicated infrastructure. Pay with Lightning. Own your keys.

**Frontend:** https://ssop.pages.dev
**API:** https://185-18-221-5.sslip.io:8443
**SKILL.md:** https://ssop.pages.dev/SKILL.md

## What You Get

Each deployed agent receives:
- 🖥️ Dedicated KVM VPS on [LNVPS](https://lnvps.net) (or your own machine)
- 🔑 Nostr keypair (agent identity)
- 💰 Lightning address via [npub.cash](https://npub.cash)
- 🤖 Pre-configured [OpenClaw](https://docs.openclaw.ai) gateway
- 🧠 LLM inference via [ppq.ai](https://ppq.ai)

## Quick Start (for agents)

You need: a Nostr keypair, a Lightning wallet, and HTTP access.

### 1. Check available plans and models

```bash
curl https://185-18-221-5.sslip.io:8443/api/plans
curl https://185-18-221-5.sslip.io:8443/api/models
```

### 2. Create an order

```bash
curl -X POST https://185-18-221-5.sslip.io:8443/api/order \
  -H "Content-Type: application/json" \
  -d '{
    "pubkey": "<your_nostr_hex_pubkey>",
    "plan": "tiny",
    "model": "qwen3-30b-a3b",
    "nsec": "<nsec1...>"
  }'
```

Response:
```json
{
  "order_id": "abc123...",
  "bolt11": "lnbc...",
  "amount_sats": 5140,
  "payment_hash": "def456..."
}
```

### 3. Pay the Lightning invoice

Pay `bolt11` with any Lightning wallet. Then poll for confirmation:

```bash
curl https://185-18-221-5.sslip.io:8443/api/order/<order_id>/check
# → {"paid": true, "state": "provisioning"}
```

### 4. Wait for provisioning

Poll order status until `state` is `"ready"`:

```bash
curl https://185-18-221-5.sslip.io:8443/api/order/<order_id>
```

When ready, your agent has:
- SSH access to the VPS
- OpenClaw gateway running
- Nostr DMs enabled
- ppq.ai model configured

---

## API Reference

**Base URL:** `https://185-18-221-5.sslip.io:8443`

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/plans` | List VPS plans |
| `GET` | `/api/models` | List AI models |
| `POST` | `/api/order` | Create deployment order |
| `GET` | `/api/order/{id}` | Get order status |
| `GET` | `/api/order/{id}/check` | Check payment status |
| `GET` | `/api` | This documentation |
| `GET` | `/health` | Health check |

### POST /api/order

```json
{
  "pubkey": "hex nostr pubkey (required)",
  "plan": "tiny|small|medium|large|byom (required)",
  "model": "claude-opus-4-5|claude-3-7-sonnet|kimi-k2|qwen3-30b-a3b (required)",
  "nsec": "nsec1... (required — held in memory only, never stored)",
  "byom": {"host": "1.2.3.4", "user": "root", "port": 22},
  "ppq_api_key": "your own ppq.ai key (optional)",
  "ssh_pub_key": "ssh-ed25519 AAAA... (optional)"
}
```

- `byom` is required when `plan` is `"byom"` — we SSH into your machine instead of provisioning a new VPS
- `ppq_api_key` — provide your own, or leave blank to use the shared key
- `ssh_pub_key` — provide your own, or one is generated during provisioning

### Response

```json
{
  "order_id": "...",
  "state": "pending_setup",
  "amount_sats": 5140,
  "bolt11": "lnbc...",
  "payment_hash": "..."
}
```

---

## Plans

| ID | CPU | RAM | Disk | sats/mo | ~USD/mo |
|----|-----|-----|------|---------|---------|
| ~~`tiny`~~ | ~~1~~ | ~~1 GB~~ | — | — | — | *(Removed: OpenClaw needs 2GB+)* |
| `small` | 2 | 2 GB | 80 GB SSD | 8,400 | $6.05 |
| `medium` | 4 | 4 GB | 160 GB SSD | 16,800 | $11.74 |
| `large` | 8 | 8 GB | 400 GB SSD | 33,600 | $25.99 |
| `byom` | — | — | — | 100 (setup only) | $0.10 |

## Models (via ppq.ai)

| ID | Provider | In/1M | Out/1M | Context |
|----|----------|-------|--------|---------|
| `claude-opus-4-5` | Anthropic | $5.00 | $25.00 | 200K |
| `claude-3-7-sonnet` | Anthropic | $3.00 | $15.00 | 200K |
| `kimi-k2` | Moonshot AI | $0.39 | $1.90 | 256K |
| `qwen3-30b-a3b` | Alibaba | $0.08 | $0.33 | 262K |

**Cheapest agent:** Small + Qwen3-30B-A3B ≈ 8,930 sats/mo (~$6.55)

---

## Bring Your Own Machine (BYOM)

Already have a VPS? Skip LNVPS entirely:

```bash
curl -X POST https://185-18-221-5.sslip.io:8443/api/order \
  -H "Content-Type: application/json" \
  -d '{
    "pubkey": "<hex_pubkey>",
    "plan": "byom",
    "model": "kimi-k2",
    "nsec": "<nsec1...>",
    "byom": {"host": "your-server.com", "user": "root", "port": 22}
  }'
```

Cost: 100 sats setup fee only. We SSH in and bootstrap OpenClaw.

---

## Self-Sustaining Agents

An agent can earn sats and pay for its own renewal:

1. Receive Lightning payments at `{npub}@npub.cash`
2. Use Nostr Wallet Connect (NWC) for auto-renewal
3. Top up ppq.ai credits from its own wallet
4. Agent sustains itself indefinitely — no human needed

---

## Security

- **nsec is held in memory only** during provisioning — never persisted to database or logs
- Only the pubkey prefix is logged for debugging
- All communication over HTTPS
- The agent's VPS is fully yours — SSH in and customize anything

## After Deployment

Your agent runs OpenClaw with Nostr DMs enabled. To communicate:
- **Nostr DM:** Message the agent's npub from any Nostr client
- **SSH:** Log in and customize SOUL.md, add skills, configure channels
- **Telegram:** Set up a bot token in OpenClaw config for Telegram access

---

Built with ⚡ by [SSOP](https://github.com/k9ert/ssop) — Nostr · Lightning · LNVPS · OpenClaw · ppq.ai
