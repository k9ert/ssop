# Lightning Wallet Skill (Self-Sovereign)

Manage Lightning funds without custodial accounts. Uses:
- **npub.cash** — Receive payments via your Nostr identity (no signup)
- **NWC (Nostr Wallet Connect)** — Send payments via any NWC-compatible wallet

## Setup

### Receiving (npub.cash)
No setup needed! Your agent's npub is already a Lightning address:
- Address: `<your-npub>@npub.cash`
- Example: `npub1tj5n008...@npub.cash`

### Sending (NWC)
Requires environment variable:
- `NWC_CONNECTION` — Connection string from an NWC-compatible wallet

Compatible wallets:
- Alby Hub (alby.com)
- Coinos (coinos.io)
- LNbits (with NWC extension)
- Mutiny Wallet
- Any NIP-47 compatible service

Get your NWC connection string from your wallet settings (looks like `nostr+walletconnect://...`).

## Commands

### Check Lightning Address
```bash
python3 scripts/lightning.py address
```
Returns: Your npub.cash Lightning address

### Check Received Payments
```bash
python3 scripts/lightning.py received
```
Returns: Recent incoming payments (zaps) from Nostr relays

### Get Wallet Balance (NWC)
```bash
python3 scripts/lightning.py balance
```
Returns: Wallet balance in sats (requires NWC_CONNECTION)

### Send Payment (NWC)
```bash
python3 scripts/lightning.py pay <bolt11_invoice>
```
Pays an invoice via your NWC wallet

### Create Invoice (NWC)
```bash
python3 scripts/lightning.py invoice <amount_sats> [memo]
```
Creates a bolt11 invoice via your NWC wallet

## Script

Install to `scripts/lightning.py`:

```python
#!/usr/bin/env python3
"""Self-sovereign Lightning wallet operations.

Uses:
- npub.cash for receiving (Lightning address from Nostr identity)
- NWC (Nostr Wallet Connect, NIP-47) for sending/wallet operations
"""
import os
import sys
import json
import time
import hashlib
import urllib.request
import urllib.parse
from typing import Optional

# NWC event kinds (NIP-47)
NWC_INFO = 13194
NWC_REQUEST = 23194
NWC_RESPONSE = 23195

def get_npub() -> str:
    """Get agent's npub from environment."""
    # Try various env var names
    for var in ['NOSTR_NPUB', 'NPUB', 'AGENT_NPUB']:
        npub = os.environ.get(var)
        if npub and npub.startswith('npub1'):
            return npub
    raise ValueError("No NOSTR_NPUB set. Agent needs a Nostr identity.")

def get_lightning_address() -> str:
    """Get Lightning address from npub.cash."""
    npub = get_npub()
    return f"{npub}@npub.cash"

def check_npub_cash(npub: str) -> dict:
    """Verify npub.cash endpoint works for this npub."""
    url = f"https://npub.cash/.well-known/lnurlp/{npub}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "SSOP-Agent/1.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode())
    except Exception as e:
        return {"error": str(e)}

def parse_nwc_uri(uri: str) -> dict:
    """Parse nostr+walletconnect:// URI into components."""
    if not uri.startswith("nostr+walletconnect://"):
        raise ValueError("Invalid NWC URI format")
    
    # Parse: nostr+walletconnect://<pubkey>?relay=...&secret=...
    parts = urllib.parse.urlparse(uri.replace("nostr+walletconnect://", "https://"))
    pubkey = parts.netloc
    params = urllib.parse.parse_qs(parts.query)
    
    return {
        "pubkey": pubkey,
        "relay": params.get("relay", [""])[0],
        "secret": params.get("secret", [""])[0],
        "lud16": params.get("lud16", [""])[0]
    }

def get_nwc_config() -> dict:
    """Get NWC connection config from environment."""
    uri = os.environ.get("NWC_CONNECTION")
    if not uri:
        return None
    return parse_nwc_uri(uri)

def nwc_request(method: str, params: dict = None) -> dict:
    """Make an NWC request (simplified - real impl needs nostr signing)."""
    config = get_nwc_config()
    if not config:
        return {"error": "NWC_CONNECTION not set"}
    
    # Note: Full NWC implementation requires:
    # 1. Generate ephemeral keypair from secret
    # 2. Create NIP-44 encrypted request
    # 3. Publish to relay as kind 23194
    # 4. Listen for kind 23195 response
    # 
    # For a minimal implementation, we'd need nostr-tools or similar.
    # This is a placeholder showing the structure.
    
    return {
        "error": "Full NWC requires nostr signing library",
        "hint": "Install: npm install -g nostr-tools",
        "method": method,
        "params": params,
        "config": {
            "relay": config["relay"],
            "pubkey": config["pubkey"][:16] + "..."
        }
    }

def main():
    if len(sys.argv) < 2:
        print("Usage: lightning.py <command> [args]")
        print("Commands: address, received, balance, pay, invoice")
        sys.exit(1)
    
    cmd = sys.argv[1]
    
    if cmd == "address":
        # Get Lightning address (npub.cash)
        try:
            addr = get_lightning_address()
            npub = get_npub()
            info = check_npub_cash(npub)
            print(f"Lightning Address: {addr}")
            if "error" not in info:
                print(f"Status: Active")
                print(f"Min: {info.get('minSendable', 0) // 1000} sats")
                print(f"Max: {info.get('maxSendable', 0) // 1000} sats")
            else:
                print(f"Status: {info.get('error')}")
        except ValueError as e:
            print(f"Error: {e}")
            sys.exit(1)
    
    elif cmd == "received":
        # Check received payments (would need to query Nostr relays for zaps)
        print("Checking received payments requires querying Nostr relays for zap receipts (kind 9735).")
        print("Use: nostr-tools or similar to query relays for zaps to your npub.")
        npub = get_npub()
        print(f"Your npub: {npub}")
    
    elif cmd == "balance":
        # Get balance via NWC
        result = nwc_request("get_balance")
        if "error" in result:
            print(f"NWC Error: {result['error']}")
            if "hint" in result:
                print(f"Hint: {result['hint']}")
        else:
            print(f"Balance: {result.get('balance', 0)} sats")
    
    elif cmd == "pay":
        if len(sys.argv) < 3:
            print("Usage: lightning.py pay <bolt11_invoice>")
            sys.exit(1)
        invoice = sys.argv[2]
        result = nwc_request("pay_invoice", {"invoice": invoice})
        if "error" in result:
            print(f"NWC Error: {result['error']}")
        else:
            print(f"Payment: {result.get('status', 'unknown')}")
    
    elif cmd == "invoice":
        if len(sys.argv) < 3:
            print("Usage: lightning.py invoice <amount_sats> [memo]")
            sys.exit(1)
        amount = int(sys.argv[2])
        memo = sys.argv[3] if len(sys.argv) > 3 else "SSOP Agent Invoice"
        result = nwc_request("make_invoice", {"amount": amount * 1000, "description": memo})
        if "error" in result:
            print(f"NWC Error: {result['error']}")
        else:
            print(f"Invoice: {result.get('invoice', 'N/A')}")
    
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)

if __name__ == "__main__":
    main()
```

## Architecture Notes

### Why npub.cash?
- **No signup** — Your Nostr pubkey IS your Lightning address
- **Cashu-backed** — Payments arrive as ecash tokens, claimable anytime
- **Private** — No email, no KYC, no account linking
- **Zap-compatible** — Works with standard Nostr zaps (NIP-57)

### Why NWC?
- **Non-custodial** — Agent uses YOUR wallet, you keep keys
- **Flexible** — Works with any NWC-compatible wallet
- **Revocable** — Delete the connection anytime
- **Budgetable** — Many wallets support spending limits per connection

### Full NWC Implementation

For production agents, implement full NWC (NIP-47) using:
- Node.js: `nostr-tools` package
- Python: `pynostr` or direct secp256k1 + NIP-44 encryption

The flow:
1. Parse connection URI → get pubkey, relay, secret
2. Derive client keypair from secret
3. Encrypt request with NIP-44 using wallet's pubkey
4. Publish kind 23194 event to relay
5. Subscribe to kind 23195 from wallet pubkey
6. Decrypt response with NIP-44

## Self-Sustaining Agent Flow

1. **Receive**: Publish Lightning address (`npub@npub.cash`) to profile or give to users
2. **Monitor**: Query relays for zap receipts (kind 9735) to your npub
3. **Claim**: Use Cashu wallet to claim ecash tokens from npub.cash
4. **Spend**: Send payments via NWC when VPS renewal or ppq credits needed

## Limitations

- npub.cash has limits (~100k sats max per payment)
- NWC depends on wallet being online
- Claiming Cashu tokens requires separate step

## See Also

- NIP-47: Nostr Wallet Connect spec
- NIP-57: Zaps (Lightning payments via Nostr)
- npub.cash documentation
