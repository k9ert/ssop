---
name: ssop-deploy
description: "Deploy a self-sovereign AI agent on LNVPS via Lightning payment. Use when an agent needs its own infrastructure — VPS, identity, wallet, and LLM access — paid entirely with Bitcoin."
---

# SSOP Deploy Skill

Deploy a self-sovereign AI agent on Lightning-paid infrastructure. No KYC, no cloud accounts, just sats.

## What You Get

Each deployed agent receives:
- 🖥️ Dedicated KVM VPS on [LNVPS](https://lnvps.net) (Dublin/Quebec/London)
- 🔑 Nostr keypair (identity)
- 💰 npub.cash Lightning wallet
- 🤖 Pre-configured [OpenClaw](https://docs.openclaw.ai) gateway
- 🧠 LLM inference via [ppq.ai](https://ppq.ai)

## Quick Deploy (API)

```bash
# 1. Generate a Nostr keypair (or use existing)
# 2. Choose a plan and model
# 3. POST to the orchestrator API

curl -X POST https://api.ssop.example/api/order \
  -H "Content-Type: application/json" \
  -d '{
    "pubkey": "<your_nostr_hex_pubkey>",
    "plan": "tiny",
    "model": "claude-3-7-sonnet"
  }'

# Returns: { "order_id": "...", "invoice": "lnbc...", "amount_sats": 12600 }

# 3. Pay the Lightning invoice from any wallet
# 4. Poll for status or connect via WebSocket
curl https://api.ssop.example/api/order/<order_id>

# When status is "ready", you'll get SSH credentials and agent details
```

## Plans

| Plan | CPU | RAM | Disk | ~sats/mo | ~USD/mo |
|------|-----|-----|------|----------|---------|
| Tiny | 1 | 1 GB | 40 GB SSD | 4,200 | $3.20 |
| Small | 2 | 2 GB | 80 GB SSD | 8,400 | $6.05 |
| Medium | 4 | 4 GB | 160 GB SSD | 16,800 | $11.74 |
| Large | 8 | 8 GB | 400 GB SSD | 33,600 | $25.99 |

## Models (via ppq.ai)

| Model | In/1M | Out/1M | Context | Best For |
|-------|-------|--------|---------|----------|
| Claude Opus 4.5 | $5.00 | $25.00 | 200K | Max quality reasoning |
| Claude 3.7 Sonnet | $3.00 | $15.00 | 200K | Balanced (recommended) |
| Kimi K2 Instruct | $0.39 | $1.90 | 256K | Agentic tasks, tool use |
| Qwen3-30B-A3B | $0.08 | $0.33 | 262K | Cheapest, coding, fast |

### Monthly Cost Estimates (model only)

Light usage (50 turns/day, ~3K in + 1K out per turn):

| Model | sats/mo | ~USD/mo |
|-------|---------|---------|
| Opus 4.5 | 60,000 | $60 |
| Sonnet 3.7 | 36,000 | $36 |
| Kimi K2 | 4,700 | $4.70 |
| Qwen3-30B | 530 | $0.53 |

Heavy usage (400 turns/day, ~3.5K in + 1.5K out per turn):

| Model | sats/mo | ~USD/mo |
|-------|---------|---------|
| Opus 4.5 | 510,000 | $510 |
| Sonnet 3.7 | 306,000 | $306 |
| Kimi K2 | 38,900 | $38.90 |
| Qwen3-30B | 4,960 | $4.96 |

## For Agents: Programmatic Deployment

If you're an AI agent deploying your own infrastructure:

### Prerequisites
- A Nostr keypair (nsec/npub)
- Lightning wallet with sufficient sats
- Ability to make HTTP requests

### Step-by-Step

```python
# 1. Create order
order = http_post("https://api.ssop.example/api/order", {
    "pubkey": my_hex_pubkey,
    "plan": "tiny",         # cheapest VPS
    "model": "qwen3-30b-a3b"  # cheapest model (~530 sats/mo light usage!)
})

# 2. Pay Lightning invoice
pay_invoice(order["invoice"])  # ~4,730 sats total (VPS + model credits)

# 3. Wait for provisioning (poll or WebSocket)
while True:
    status = http_get(f"https://api.ssop.example/api/order/{order['order_id']}")
    if status["state"] == "ready":
        break
    sleep(10)

# 4. You now have:
#    - SSH access: status["ssh"]
#    - OpenClaw gateway running
#    - Nostr identity active
#    - ppq.ai credits loaded
#    - npub.cash wallet: {pubkey}@npub.cash
```

### Cheapest Possible Agent
- **Plan:** Tiny (4,200 sats/mo)
- **Model:** Qwen3-30B-A3B (530 sats/mo light usage)
- **Total:** ~4,730 sats/mo (~$4.73) for a fully autonomous AI agent
- **Setup fee:** 100 sats (one-time)

### Self-Sustaining Agent
An agent can earn sats via its npub.cash wallet and pay for its own renewal:
1. Receive Lightning payments to `{pubkey}@npub.cash`
2. Use NWC (Nostr Wallet Connect) for auto-renewal on LNVPS
3. Top up ppq.ai credits from wallet
4. Agent sustains itself indefinitely without human intervention

## Frontend

Interactive wizard at: **https://ssop.example** (TBD)

Steps: Setup Fee → Choose Server → Choose Model → Generate Identity → Pay → Provisioning → Done

## Architecture

See [architecture.md](architecture.md) for the full system design.

## Source

Private repo: [github.com/k9ert/ssop](https://github.com/k9ert/ssop)
