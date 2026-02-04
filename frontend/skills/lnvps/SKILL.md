# LNVPS Manager Skill

Manage your LNVPS VM: check status, expiry, request renewal invoices.

## Setup

Requires environment variable:
- `NOSTR_NSEC` — your Nostr private key (for NIP-98 auth)

Also needs `nostr-tools` npm package installed globally.

## Commands

### Check VM Status
```bash
python3 scripts/lnvps.py vm-info <vm_id>
```
Returns: VM details including expiry date.

### List Your VMs
```bash
python3 scripts/lnvps.py vms
```

### Get Renewal Invoice
```bash
python3 scripts/lnvps.py vm-payment <vm_id>
```
Returns: Lightning invoice for renewal.

## Script

Install to `scripts/lnvps.py`:

```python
#!/usr/bin/env python3
"""LNVPS API client using NIP-98 Nostr authentication."""
import os
import sys
import json
import time
import base64
import hashlib
import urllib.request
import subprocess

API_BASE = "https://api.lnvps.net/api/v1"

def get_nsec():
    nsec = os.environ.get("NOSTR_NSEC")
    if not nsec:
        raise ValueError("NOSTR_NSEC not set")
    return nsec

def create_nip98_header(url, method="GET"):
    """Create NIP-98 auth header using nostr-tools."""
    nsec = get_nsec()
    js_code = f'''
    const {{ finalizeEvent, getPublicKey }} = require("nostr-tools/pure");
    const {{ decode: nip19Decode }} = require("nostr-tools/nip19");
    const sk = nip19Decode("{nsec}").data;
    const event = finalizeEvent({{
        kind: 27235,
        created_at: Math.floor(Date.now() / 1000),
        tags: [["u", "{url}"], ["method", "{method}"]],
        content: ""
    }}, sk);
    console.log(JSON.stringify(event));
    '''
    result = subprocess.run(
        ["node", "-e", js_code],
        capture_output=True, text=True,
        env={{**os.environ, "NODE_PATH": "/usr/lib/node_modules"}}
    )
    if result.returncode != 0:
        raise Exception(f"NIP-98 signing failed: {{result.stderr}}")
    event = json.loads(result.stdout.strip())
    token = base64.b64encode(json.dumps(event).encode()).decode()
    return f"Nostr {{token}}"

def api_request(endpoint, method="GET", data=None):
    url = f"{{API_BASE}}{{endpoint}}"
    auth = create_nip98_header(url, method)
    headers = {{"Authorization": auth, "Content-Type": "application/json"}}
    
    req = urllib.request.Request(url, headers=headers, method=method)
    if data:
        req.data = json.dumps(data).encode()
    
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())

def get_vms():
    return api_request("/vm")

def get_vm_info(vm_id):
    return api_request(f"/vm/{{vm_id}}")

def get_vm_payment(vm_id):
    return api_request(f"/vm/{{vm_id}}/payment", "PUT")

def days_until_expiry(vm_info):
    """Calculate days until VM expires."""
    from datetime import datetime
    expires = vm_info.get("data", {{}}).get("expires")
    if not expires:
        return None
    exp_date = datetime.fromisoformat(expires.replace("Z", "+00:00"))
    now = datetime.now(exp_date.tzinfo)
    return (exp_date - now).days

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: lnvps.py <vms|vm-info|vm-payment> [vm_id]")
        sys.exit(1)
    
    cmd = sys.argv[1]
    
    if cmd == "vms":
        result = get_vms()
        print(json.dumps(result, indent=2))
    elif cmd == "vm-info" and len(sys.argv) > 2:
        result = get_vm_info(sys.argv[2])
        days = days_until_expiry(result)
        print(json.dumps(result, indent=2))
        if days is not None:
            print(f"\\nDays until expiry: {{days}}")
    elif cmd == "vm-payment" and len(sys.argv) > 2:
        result = get_vm_payment(sys.argv[2])
        print(json.dumps(result, indent=2))
    else:
        print("Unknown command or missing args")
        sys.exit(1)
```

## Integration with Heartbeat

Heartbeat checks `days_until_expiry()`. Default alert: < 7 days remaining.

## Auto-Renewal Flow

1. Heartbeat detects < 7 days remaining
2. Request renewal invoice via `vm-payment`
3. Pay invoice using lightning skill
4. Confirm renewal succeeded
5. Notify owner of renewal (or failure)

## Thresholds

- Alert: 7 days before expiry
- Critical: 3 days before expiry
- Auto-renew: Optional, requires sufficient wallet balance
