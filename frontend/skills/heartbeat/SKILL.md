# Self-Preservation Heartbeat Skill

Monitor critical resources and alert owner before running out.

## Purpose

A self-sovereign agent must:
1. Know when it's running low on funds
2. Know when its VM is about to expire
3. Know when its AI credits are depleted
4. Alert its owner before going silent

## Setup

Requires all of:
- Lightning skill (wallet balance)
- PPQ skill (AI credits)
- LNVPS skill (VM status)

Environment variables:
- `OWNER_NPUB` — owner's Nostr npub for alerts
- `VM_ID` — this agent's LNVPS VM ID
- `SSOP_ALERT_WALLET_SATS` — wallet alert threshold (default: 10000)
- `SSOP_ALERT_VM_DAYS` — VM expiry alert threshold (default: 7)

## Heartbeat Check Script

Add to `HEARTBEAT.md`:

```markdown
## SSOP Self-Preservation (every heartbeat)

Run the survival check:
1. `python3 scripts/ssop_heartbeat.py`
2. If any alerts returned, notify owner via Nostr DM
3. If critical (< 1 day VM or < 1000 sats), send URGENT alert
```

## Script

Install to `scripts/ssop_heartbeat.py`:

```python
#!/usr/bin/env python3
"""SSOP Self-Preservation Heartbeat Check."""
import os
import sys
import json
import subprocess

# Thresholds (configurable via env)
WALLET_ALERT_SATS = int(os.environ.get("SSOP_ALERT_WALLET_SATS", "10000"))
VM_ALERT_DAYS = int(os.environ.get("SSOP_ALERT_VM_DAYS", "7"))
VM_ID = os.environ.get("VM_ID")

def run_script(script, *args):
    """Run a skill script and return output."""
    try:
        result = subprocess.run(
            ["python3", f"scripts/{script}", *args],
            capture_output=True, text=True, timeout=30
        )
        return result.stdout.strip(), result.returncode == 0
    except Exception as e:
        return str(e), False

def check_wallet():
    """Check Lightning wallet balance."""
    output, ok = run_script("lightning.py", "balance")
    if not ok:
        return {"status": "error", "message": output}
    
    # Parse "BTC: X sats"
    try:
        sats = int(output.split(":")[1].strip().replace(",", "").replace(" sats", ""))
        if sats < WALLET_ALERT_SATS:
            return {
                "status": "alert",
                "resource": "wallet",
                "value": sats,
                "threshold": WALLET_ALERT_SATS,
                "message": f"Wallet low: {sats:,} sats (threshold: {WALLET_ALERT_SATS:,})"
            }
        return {"status": "ok", "value": sats}
    except:
        return {"status": "error", "message": f"Failed to parse: {output}"}

def check_vm():
    """Check VM expiry."""
    if not VM_ID:
        return {"status": "skip", "message": "VM_ID not set"}
    
    output, ok = run_script("lnvps.py", "vm-info", VM_ID)
    if not ok:
        return {"status": "error", "message": output}
    
    # Parse days until expiry from output
    try:
        lines = output.split("\n")
        for line in lines:
            if "Days until expiry:" in line:
                days = int(line.split(":")[1].strip())
                if days < VM_ALERT_DAYS:
                    return {
                        "status": "alert",
                        "resource": "vm",
                        "value": days,
                        "threshold": VM_ALERT_DAYS,
                        "message": f"VM expires in {days} days! (threshold: {VM_ALERT_DAYS})"
                    }
                return {"status": "ok", "value": days}
        return {"status": "error", "message": "Could not parse VM expiry"}
    except:
        return {"status": "error", "message": f"Failed to parse VM info"}

def check_ppq():
    """Check PPQ credits (if endpoint available)."""
    output, ok = run_script("ppq_balance.py", "balance")
    if not ok or "error" in output.lower():
        return {"status": "skip", "message": "PPQ balance check not available"}
    
    # PPQ balance parsing depends on their API response format
    # For now, just report what we got
    return {"status": "info", "raw": output}

def main():
    results = {
        "wallet": check_wallet(),
        "vm": check_vm(),
        "ppq": check_ppq()
    }
    
    alerts = [r for r in results.values() if r.get("status") == "alert"]
    errors = [r for r in results.values() if r.get("status") == "error"]
    
    print(json.dumps({
        "timestamp": __import__("datetime").datetime.utcnow().isoformat() + "Z",
        "checks": results,
        "alerts": len(alerts),
        "errors": len(errors),
        "alert_messages": [a["message"] for a in alerts]
    }, indent=2))
    
    # Exit code: 0 = ok, 1 = alerts, 2 = errors
    if errors:
        sys.exit(2)
    elif alerts:
        sys.exit(1)
    else:
        sys.exit(0)

if __name__ == "__main__":
    main()
```

## Alert Format

When alerting owner via Nostr DM:

```
⚠️ SSOP Agent Alert

Resource: wallet
Status: LOW
Current: 5,234 sats
Threshold: 10,000 sats

Action needed: Top up wallet to continue operations.

VM ID: 964
Agent npub: npub1rx6...
```

## Auto-Renewal (Optional)

If `SSOP_AUTO_RENEW=true`:
1. When VM < 7 days, request renewal invoice
2. If wallet has sufficient funds, pay automatically
3. Notify owner of auto-renewal
4. If wallet insufficient, alert owner to top up

## Integration

Add to agent's cron:
```json
{
  "name": "ssop-heartbeat",
  "schedule": {"kind": "cron", "expr": "0 */6 * * *"},
  "payload": {"kind": "systemEvent", "text": "Run SSOP self-preservation check"}
}
```

This runs every 6 hours — adjust based on needs.
