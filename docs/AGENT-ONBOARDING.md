# Agent Onboarding — Design Doc

## Overview

When a user orders an SSOP agent, we need to:
1. Provision infrastructure (VM, OpenClaw, model access)
2. Establish identity (agent Nostr keypair)
3. Connect user ↔ agent (bidirectional Nostr DMs)
4. Bootstrap the agent's personality/purpose

## Open Questions

### 1. Template Injection
**How do we fill `{{PLACEHOLDERS}}` in workspace files?**

Options:
- A. Orchestrator writes files directly via SSH after VM is up
- B. cloud-init renders templates from user-data
- C. Agent reads config from environment and fills templates on first boot
- D. Separate "provisioner" script runs post-boot

**Considerations:**
- cloud-init has size limits (~16KB user-data)
- SSH requires waiting for VM to be reachable
- Agent self-filling requires the agent to be smart enough pre-bootstrap

### 2. User Pubkey Collection
**When/how does user provide their Nostr pubkey?**

Options:
- A. Required field in order form (hex or npub)
- B. Generated for them (we give them nsec) — custody risk
- C. Optional — fall back to email/other contact
- D. Derived from Lightning payment (if using LNURL-auth or similar)

**Current frontend:** Has pubkey field in step 1 (identity)

### 3. Agent → User First Contact
**What if the first Nostr DM fails?**

Scenarios:
- User's relays don't overlap with agent's relays
- User doesn't have a Nostr client set up
- Pubkey was entered wrong

Fallback options:
- A. Agent retries on heartbeat (exponential backoff)
- B. Agent writes status to a public endpoint user can poll
- C. Email fallback (requires email in order)
- D. User must initiate contact (flip the flow)

### 4. Agent Identity
**Who generates the agent's Nostr keypair?**

Options:
- A. Orchestrator generates, injects via cloud-init/SSH
- B. Agent generates on first boot, reports back to orchestrator
- C. Pre-generated pool of keypairs

**Considerations:**
- Option A: orchestrator briefly holds nsec (acceptable?)
- Option B: how does user know agent's npub before contact?
- Option C: management overhead

### 5. Bootstrap Completion
**How do we know the agent successfully bootstrapped?**

Options:
- A. Agent calls webhook on orchestrator when done
- B. Orchestrator polls agent's health endpoint
- C. Agent sends Nostr event to a known pubkey (e.g., SSOP service)
- D. User confirms in frontend after receiving DM

### 6. Failure Modes
**What if provisioning fails partway?**

- VM created but OpenClaw won't start
- OpenClaw starts but can't reach ppq.ai
- Agent boots but Nostr plugin fails
- Agent DMs user but gets no response for days

**Need:** Timeout/refund policy, monitoring, alerting

## Proposed Flow (Draft)

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐     ┌─────────┐
│   Frontend  │────▶│  Orchestrator │────▶│   LNVPS    │────▶│  Agent  │
└─────────────┘     └──────────────┘     └─────────────┘     └─────────┘
      │                    │                    │                  │
      │ 1. Order           │                    │                  │
      │ (pubkey, plan,     │                    │                  │
      │  model)            │                    │                  │
      │───────────────────▶│                    │                  │
      │                    │                    │                  │
      │ 2. Invoice         │                    │                  │
      │◀───────────────────│                    │                  │
      │                    │                    │                  │
      │ 3. Payment         │                    │                  │
      │───────────────────▶│                    │                  │
      │                    │                    │                  │
      │                    │ 4. Create VM       │                  │
      │                    │───────────────────▶│                  │
      │                    │                    │                  │
      │                    │ 5. VM ready        │                  │
      │                    │◀───────────────────│                  │
      │                    │                    │                  │
      │                    │ 6. Provision       │                  │
      │                    │ (SSH: templates,   │                  │
      │                    │  config, start)    │─────────────────▶│
      │                    │                    │                  │
      │                    │ 7. Health check    │                  │
      │                    │◀─────────────────────────────────────│
      │                    │                    │                  │
      │ 8. Ready           │                    │                  │
      │ (agent npub,       │                    │                  │
      │  SSH creds)        │                    │                  │
      │◀───────────────────│                    │                  │
      │                    │                    │                  │
      │                    │                    │    9. DM user    │
      │◀───────────────────────────────────────────────────────────│
```

## Dependencies

- [ ] POST /api/orders endpoint (orchestrator)
- [ ] LNVPS VM creation integration
- [ ] Template rendering (orchestrator or cloud-init)
- [ ] Agent health check endpoint
- [ ] Payment verification (LNbits webhook)

## Decisions (Resolved)

1. **Template injection:** ✅ **A — Orchestrator writes via SSH** after VM is up
2. **Agent keypair:** ✅ **Passed from UI** (user creates fresh or injects existing). Orchestrator can also inject for testing.
3. **First contact:** ✅ **A — Agent DMs user** (better UX). User can still initiate if it fails.
4. **Failure handling:** ✅ **None for now** — assume Nostr DM works.

## Implementation Plan

### Orchestrator (Go)

1. **POST /api/orders** — accepts:
   - `user_pubkey` (hex) — user's Nostr pubkey
   - `agent_pubkey` (hex) — agent's Nostr pubkey  
   - `agent_nsec` — agent's Nostr private key
   - `plan` — LNVPS plan ID
   - `model` — LLM model ID

2. **After payment confirmed:**
   - Create VM via LNVPS API
   - Wait for VM to be SSH-reachable
   - SSH in and:
     - Run bootstrap script (install OpenClaw, deps)
     - Write workspace templates with placeholders filled
     - Write config with model/Nostr settings
     - Start OpenClaw gateway

3. **Return to frontend:**
   - Agent npub
   - VM IP / hostname
   - SSH credentials (optional, for debugging)

### Templates to Fill (via SSH)

| File | Placeholders |
|------|--------------|
| `USER.md` | `{{USER_PUBKEY_HEX}}`, `{{USER_NPUB}}` |
| `IDENTITY.md` | `{{AGENT_PUBKEY_HEX}}`, `{{AGENT_NPUB}}`, `{{PLAN_NAME}}`, `{{MODEL_NAME}}`, `{{REGION}}`, `{{CREATED_DATE}}` |
| `openclaw.yaml` | `{{AGENT_NSEC}}`, `{{MODEL_ENDPOINT}}`, `{{MODEL_API_KEY}}` |

### Agent Boot Sequence

1. OpenClaw starts → loads workspace files
2. Agent reads `BOOTSTRAP.md` → sees instruction to DM user
3. Agent reads `USER.md` → gets user's Nostr pubkey
4. Agent sends Nostr DM: "Hey! I just came online..."
5. User receives DM → conversation begins
6. Agent deletes `BOOTSTRAP.md` after successful intro

---

_Last updated: 2026-02-09_
