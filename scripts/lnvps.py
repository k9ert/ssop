#!/usr/bin/env python3
"""LNVPS API client using NIP-98 Nostr authentication.

Usage:
    python3 lnvps.py account          # Get account info
    python3 lnvps.py templates        # List VM templates
    python3 lnvps.py images           # List OS images
    python3 lnvps.py vms              # List your VMs
    python3 lnvps.py ssh-keys         # List SSH keys
    python3 lnvps.py payment-methods  # List payment methods
"""

import base64
import hashlib
import json
import os
import subprocess
import sys
import time
import urllib.request

API_BASE = "https://api.lnvps.net/api/v1"


def get_nsec():
    """Load nsec from environment or ~/.profile."""
    nsec = os.environ.get("NOSTR_NSEC")
    if nsec:
        return nsec
    try:
        with open(os.path.expanduser("~/.profile")) as f:
            for line in f:
                if "NOSTR_NSEC=" in line and "export" in line:
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    raise RuntimeError("NOSTR_NSEC not found in env or ~/.profile")


def create_nip98_token(url: str, method: str = "GET") -> str:
    """Create a NIP-98 HTTP Auth token using nostr-tools via Node.js."""
    nsec = get_nsec()

    # Node.js script to create and sign a NIP-98 event
    node_script = f"""
    const nostr = require('nostr-tools');
    const nsec = '{nsec}';
    const decoded = nostr.nip19.decode(nsec);
    const sk = decoded.data;
    const pk = nostr.getPublicKey(sk);

    const event = nostr.finalizeEvent({{
        kind: 27235,
        created_at: Math.floor(Date.now() / 1000),
        tags: [
            ['u', '{url}'],
            ['method', '{method}'],
        ],
        content: '',
    }}, sk);

    // NIP-98: base64 encode the JSON event
    const token = Buffer.from(JSON.stringify(event)).toString('base64');
    console.log(token);
    """

    result = subprocess.run(
        ["node", "-e", node_script],
        capture_output=True,
        text=True,
        timeout=10,
        env={**os.environ, "NODE_PATH": "/usr/lib/node_modules"},
    )

    if result.returncode != 0:
        raise RuntimeError(f"Failed to create NIP-98 token: {result.stderr}")

    return result.stdout.strip()


def api_request(path: str, method: str = "GET", body: dict = None) -> dict:
    """Make an authenticated API request to LNVPS."""
    url = f"{API_BASE}{path}"
    token = create_nip98_token(url, method)

    headers = {
        "Authorization": f"Nostr {token}",
        "Content-Type": "application/json",
    }

    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        error_body = e.read().decode() if e.fp else ""
        print(f"HTTP {e.code}: {error_body}", file=sys.stderr)
        sys.exit(1)


def api_public(path: str) -> dict:
    """Make an unauthenticated API request."""
    url = f"{API_BASE}{path}"
    req = urllib.request.Request(url, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        error_body = e.read().decode() if e.fp else ""
        print(f"HTTP {e.code}: {error_body}", file=sys.stderr)
        sys.exit(1)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "account":
        result = api_request("/account")
    elif cmd == "templates":
        result = api_public("/vm/templates")
    elif cmd == "images":
        result = api_public("/image")
    elif cmd == "vms":
        result = api_request("/vm")
    elif cmd == "ssh-keys":
        result = api_request("/ssh-key")
    elif cmd == "payment-methods":
        result = api_public("/payment/methods")
    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)
        sys.exit(1)

    print(json.dumps(result, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
