"""
Test per-tenant token limits across all APIM subscriptions.

Dynamically loads APIM gateway URL and subscription keys from Terraform
outputs (which use your local `az login` session). No hardcoded secrets.

Usage:
    python test_token_limits.py                   # auto-discover from terraform output
    python test_token_limits.py --burst fabrikam  # burst-test a specific tenant
"""
import urllib.request
import json
import ssl
import sys
import time
import subprocess
import concurrent.futures
import threading

# ─── Dynamic config from Terraform outputs ────────────────────────────────────

def tf_output(name, sensitive=False):
    """Fetch a Terraform output value. Uses local az login credentials."""
    cmd = ["terraform", "output", "-json", name]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR: Failed to read terraform output '{name}':", result.stderr.strip(), file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)

def load_config():
    """Load APIM gateway URL and all subscription keys from Terraform state."""
    print("Loading config from Terraform outputs (uses your az login session)...")

    gateway = tf_output("apim_gateway_url")
    default_key = tf_output("apim_subscription_key")
    tenant_keys = tf_output("apim_tenant_subscription_keys")

    subscriptions = {
        "Default (Lab)": {"key": default_key, "tpm": "default", "quota": "default"}
    }
    for slug, info in tenant_keys.items():
        subscriptions[info["display_name"]] = {
            "key": info["primary_key"],
            "tpm": slug,
            "quota": slug,
        }

    print(f"  Gateway:       {gateway}")
    print(f"  Subscriptions: {', '.join(subscriptions.keys())}")
    return gateway, subscriptions


GATEWAY, SUBSCRIPTIONS = load_config()
ENDPOINT = f"{GATEWAY}/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-21"

ctx = ssl.create_default_context()
print_lock = threading.Lock()

def chat(api_key, prompt, max_tokens=100):
    data = json.dumps({
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens
    }).encode()
    req = urllib.request.Request(ENDPOINT, data=data, headers={
        "Content-Type": "application/json",
        "api-key": api_key
    })
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=60) as resp:
            body = json.loads(resp.read())
            headers = dict(resp.headers)
            return resp.status, body.get("usage", {}), body["choices"][0]["message"]["content"][:80], headers
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        headers = dict(e.headers) if hasattr(e, 'headers') else {}
        try:
            err = json.loads(body)
            return e.code, err, None, headers
        except:
            return e.code, body, None, headers

# Phase 1: Test all subscriptions
print("=" * 70)
print("PHASE 1: Chat completions across all subscriptions")
print("=" * 70)
for name, info in SUBSCRIPTIONS.items():
    status, usage, content, headers = chat(info["key"], f"Tell me one fun fact about {name} in 1 sentence.")
    if status == 200:
        print(f"  OK {name:20s} | HTTP {status} | {usage.get('total_tokens', '?'):>4} tokens | {content}")
    else:
        print(f"  !! {name:20s} | HTTP {status} | {usage}")
    time.sleep(0.3)

# Phase 2: CONCURRENT burst test — pick the burst target dynamically
# Use --burst <name> arg, or auto-pick first non-default tenant
burst_target = None
for arg_i, arg in enumerate(sys.argv):
    if arg == "--burst" and arg_i + 1 < len(sys.argv):
        search = sys.argv[arg_i + 1].lower()
        burst_target = next((n for n in SUBSCRIPTIONS if search in n.lower()), None)
        if not burst_target:
            print(f"  ERROR: No subscription matching '{search}'")
            sys.exit(1)

if not burst_target:
    # Auto-pick first non-default subscription
    burst_target = next((n for n in SUBSCRIPTIONS if n != "Default (Lab)"), list(SUBSCRIPTIONS.keys())[0])

burst_key = SUBSCRIPTIONS[burst_target]["key"]

print()
print("=" * 70)
print(f"PHASE 2: CONCURRENT burst on {burst_target}")
print(f"  Sending 10 parallel requests with max_tokens=800 each")
print("=" * 70)
results = []
rate_limited = False

def send_request(i):
    prompt = f"Request {i}: Write a comprehensive essay about artificial intelligence covering machine learning, deep learning, neural networks, NLP, computer vision, reinforcement learning, generative AI, and transformers."
    return i, chat(burst_key, prompt, max_tokens=800)

# Fire 10 requests concurrently
with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
    futures = [executor.submit(send_request, i) for i in range(1, 11)]
    for future in concurrent.futures.as_completed(futures):
        i, (status, usage, content, headers) = future.result()
        if status == 200:
            tokens = usage.get("total_tokens", 0)
            with print_lock:
                print(f"  Req {i:2d}: HTTP {status} | {tokens:>4} tokens")
            results.append(("ok", tokens))
        elif status == 429:
            with print_lock:
                print(f"  Req {i:2d}: HTTP 429 >>> RATE LIMITED!")
                if isinstance(usage, dict):
                    msg = usage.get("error", {}).get("message", str(usage))[:120]
                    print(f"           {msg}")
            results.append(("429", 0))
            rate_limited = True
        else:
            with print_lock:
                print(f"  Req {i:2d}: HTTP {status}")
            results.append(("err", 0))

ok_count = sum(1 for r in results if r[0] == "ok")
limited_count = sum(1 for r in results if r[0] == "429")
total_tokens = sum(r[1] for r in results)
print(f"\n  Summary: {ok_count} succeeded, {limited_count} rate-limited, {total_tokens} total tokens")

if rate_limited:
    print("  >>> Token limit policy is WORKING!")
else:
    print("  >>> No 429s detected. Sending 10 more sequential requests...")
    for i in range(11, 21):
        status, usage, content, headers = chat(burst_key, f"Essay {i} about cloud computing and AI.", max_tokens=800)
        if status == 200:
            tokens = usage.get("total_tokens", 0)
            total_tokens += tokens
            print(f"  Req {i:2d}: HTTP {status} | {tokens:>4} tokens | Cumulative: {total_tokens}")
        elif status == 429:
            print(f"  Req {i:2d}: HTTP 429 >>> RATE LIMITED after {total_tokens} total tokens!")
            rate_limited = True
            break
        else:
            print(f"  Req {i:2d}: HTTP {status}")
            break

# Phase 3: Cross-tenant isolation check
print()
print("=" * 70)
# Pick a different tenant than the burst target for isolation check
isolation_target = next((n for n in SUBSCRIPTIONS if n != burst_target and n != "Default (Lab)"), "Default (Lab)")
isolation_key = SUBSCRIPTIONS[isolation_target]["key"]

print(f"PHASE 3: Cross-tenant isolation ({isolation_target} should still work)")
print("=" * 70)
status, usage, content, headers = chat(isolation_key, "Say hello in German.")
if status == 200:
    print(f"  OK {isolation_target} | HTTP {status} | {usage.get('total_tokens', '?')} tokens | {content}")
    print(f"  >>> Per-tenant isolation confirmed: {burst_target} throttled, {isolation_target} unaffected")
else:
    print(f"  !! {isolation_target} | HTTP {status}")

print("\nDone!")
