# PPQ Usage Monitor Skill

Track ppq.ai credits and usage. Alert when balance is low.

## Setup

Requires environment variable:
- `PPQ_API_KEY` — your ppq.ai API key (starts with `sk-`)

## Commands

### Check Balance
```bash
python3 scripts/ppq_balance.py
```
Returns: Current credit balance and usage stats.

### Check Usage (last N days)
```bash
python3 scripts/ppq_balance.py usage 7
```

## Script

Install to `scripts/ppq_balance.py`:

```python
#!/usr/bin/env python3
"""PPQ.ai balance and usage checker."""
import os
import sys
import json
import urllib.request

PPQ_API = "https://api.ppq.ai/v1"

def get_headers():
    api_key = os.environ.get("PPQ_API_KEY")
    if not api_key:
        raise ValueError("PPQ_API_KEY not set")
    return {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json"
    }

def get_balance():
    """Get current credit balance."""
    req = urllib.request.Request(
        f"{PPQ_API}/dashboard/credits",
        headers=get_headers()
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
            return data
    except urllib.error.HTTPError as e:
        # PPQ might not have a credits endpoint - check /me or similar
        return {"error": str(e), "note": "Credits endpoint may not exist"}

def get_usage():
    """Get usage statistics."""
    req = urllib.request.Request(
        f"{PPQ_API}/dashboard/usage",
        headers=get_headers()
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        return {"error": str(e)}

def estimate_cost(model_id, input_tokens, output_tokens):
    """Estimate cost for a given model and token count."""
    # Approximate ppq.ai pricing (check their docs for current rates)
    rates = {
        "anthropic/claude-3.7-sonnet": {"input": 3.0, "output": 15.0},  # per 1M tokens
        "qwen/qwen3-30b-a3b": {"input": 0.1, "output": 0.3},
        "moonshotai/kimi-k2": {"input": 0.5, "output": 1.5},
    }
    rate = rates.get(model_id, {"input": 1.0, "output": 3.0})
    cost = (input_tokens * rate["input"] + output_tokens * rate["output"]) / 1_000_000
    return cost

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "balance"
    
    if cmd == "balance":
        result = get_balance()
        print(json.dumps(result, indent=2))
    elif cmd == "usage":
        result = get_usage()
        print(json.dumps(result, indent=2))
    elif cmd == "estimate":
        if len(sys.argv) < 5:
            print("Usage: ppq_balance.py estimate <model> <input_tokens> <output_tokens>")
            sys.exit(1)
        cost = estimate_cost(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
        print(f"Estimated cost: ${cost:.6f}")
    else:
        print("Usage: ppq_balance.py <balance|usage|estimate>")
        sys.exit(1)
```

## Note on PPQ API

PPQ.ai is OpenAI-compatible. The balance/usage endpoints may vary — check their documentation. Some providers track usage via dashboard only.

## Integration with Heartbeat

Heartbeat checks balance periodically. Default alert: < $1.00 remaining.

## Cost Awareness

Agents should be aware of approximate costs:
- Sonnet: ~$3/M input, ~$15/M output tokens
- Qwen3: ~$0.10/M input, ~$0.30/M output tokens
- Average message: ~1000 input + 500 output tokens ≈ $0.01-0.02 for Sonnet
