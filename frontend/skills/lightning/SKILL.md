# Lightning Wallet Skill

Manage Lightning funds via Blink API. Check balances, send payments, generate invoices.

## Setup

Requires environment variables:
- `BLINK_API_KEY` — from blink.sv dashboard
- `BLINK_BTC_WALLET_ID` — your BTC wallet ID

## Commands

### Check Balance
```bash
python3 scripts/lightning.py balance
```
Returns: `BTC: X sats`

### Send Payment
```bash
python3 scripts/lightning.py pay <bolt11_invoice>
```
Returns: `Payment status: SUCCESS` or error

### Create Invoice
```bash
python3 scripts/lightning.py invoice <amount_sats> [memo]
```
Returns: bolt11 invoice string

## Script

Install to `scripts/lightning.py`:

```python
#!/usr/bin/env python3
"""Lightning wallet operations via Blink API."""
import os
import sys
import json
import urllib.request

BLINK_API = "https://api.blink.sv/graphql"

def get_headers():
    api_key = os.environ.get("BLINK_API_KEY")
    if not api_key:
        raise ValueError("BLINK_API_KEY not set")
    return {
        "Content-Type": "application/json",
        "X-API-KEY": api_key
    }

def graphql(query, variables=None):
    payload = {"query": query}
    if variables:
        payload["variables"] = variables
    req = urllib.request.Request(
        BLINK_API,
        data=json.dumps(payload).encode(),
        headers=get_headers()
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode())

def get_balance():
    wallet_id = os.environ.get("BLINK_BTC_WALLET_ID")
    query = """
    query GetWallet($walletId: WalletId!) {
      me {
        defaultAccount {
          walletById(walletId: $walletId) {
            balance
          }
        }
      }
    }
    """
    result = graphql(query, {"walletId": wallet_id})
    balance = result["data"]["me"]["defaultAccount"]["walletById"]["balance"]
    return balance

def pay_invoice(bolt11):
    wallet_id = os.environ.get("BLINK_BTC_WALLET_ID")
    mutation = """
    mutation PayInvoice($input: LnInvoicePaymentInput!) {
      lnInvoicePaymentSend(input: $input) {
        status
        errors { message }
      }
    }
    """
    result = graphql(mutation, {
        "input": {"walletId": wallet_id, "paymentRequest": bolt11}
    })
    data = result["data"]["lnInvoicePaymentSend"]
    if data["errors"]:
        return f"Error: {data['errors'][0]['message']}"
    return f"Payment status: {data['status']}"

def create_invoice(amount_sats, memo="SSOP Agent"):
    wallet_id = os.environ.get("BLINK_BTC_WALLET_ID")
    mutation = """
    mutation CreateInvoice($input: LnInvoiceCreateOnBehalfOfRecipientInput!) {
      lnInvoiceCreateOnBehalfOfRecipient(input: $input) {
        invoice { paymentRequest }
        errors { message }
      }
    }
    """
    result = graphql(mutation, {
        "input": {
            "recipientWalletId": wallet_id,
            "amount": amount_sats,
            "memo": memo
        }
    })
    data = result["data"]["lnInvoiceCreateOnBehalfOfRecipient"]
    if data["errors"]:
        return f"Error: {data['errors'][0]['message']}"
    return data["invoice"]["paymentRequest"]

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: lightning.py <balance|pay|invoice> [args]")
        sys.exit(1)
    
    cmd = sys.argv[1]
    
    if cmd == "balance":
        sats = get_balance()
        print(f"BTC: {sats:,} sats")
    elif cmd == "pay" and len(sys.argv) > 2:
        print(pay_invoice(sys.argv[2]))
    elif cmd == "invoice" and len(sys.argv) > 2:
        amount = int(sys.argv[2])
        memo = sys.argv[3] if len(sys.argv) > 3 else "SSOP Agent"
        print(create_invoice(amount, memo))
    else:
        print("Unknown command or missing args")
        sys.exit(1)
```

## Integration with Heartbeat

The heartbeat skill uses this to check if wallet has enough funds for renewals.

## Thresholds

Default alert threshold: 10,000 sats (configurable in heartbeat skill).
