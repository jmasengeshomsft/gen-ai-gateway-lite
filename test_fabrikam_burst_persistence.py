"""
Fabrikam burst + quota persistence test
========================================
A focused proof that the Redis-backed hourly quota counter for Fabrikam
survives TPM-window resets and is consistent *between* script runs.

What it does
------------
  Burst 1  — send up to --requests requests (default 5) and print the quota
              remaining after each one.
  Wait     — pause for --wait seconds (default 65, just over one TPM window)
              so the per-minute rate-limit counter resets.
  Burst 2  — send one small "ping" request and compare its quota-remaining
              header to the value at the end of Burst 1.

Pass criteria
-------------
  |run1_remaining - run2_remaining| < 500 tokens
  → The Redis key was not reset between bursts; quota accumulates correctly.

Usage
-----
  python test_fabrikam_burst_persistence.py
  python test_fabrikam_burst_persistence.py --requests 3 --wait 10
  python test_fabrikam_burst_persistence.py --no-wait   # skip the pause (same-run check only)
"""
import json
import math
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request


# ── Config ────────────────────────────────────────────────────────────────────
TENANT_SLUG   = "fabrikam"
MAX_TOKENS    = 400   # small enough to stay under TPM, big enough to show counter moving
PROMPT        = (
    "In three sentences, explain what Azure API Management is "
    "and why Redis-backed quota counters matter for multi-tenant AI gateways."
)
PING_MAX_TOKENS = 20
PING_PROMPT   = "Say hello."

# ── Helpers ───────────────────────────────────────────────────────────────────
_ssl_ctx = ssl.create_default_context()


def _tf(name: str):
    r = subprocess.run(
        ["terraform", "output", "-json", name],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"ERROR: terraform output '{name}': {r.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return json.loads(r.stdout)


def _chat(gateway: str, api_key: str, prompt: str, max_tokens: int):
    url  = (f"{gateway}/openai/deployments/gpt-4o-mini/chat/completions"
            "?api-version=2024-10-21")
    data = json.dumps({
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
    }).encode()
    req = urllib.request.Request(url, data=data, headers={
        "Content-Type": "application/json",
        "api-key": api_key,
    })
    try:
        with urllib.request.urlopen(req, context=_ssl_ctx, timeout=60) as resp:
            body = json.loads(resp.read())
            return resp.status, body.get("usage", {}), dict(resp.headers)
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        hdr = dict(e.headers) if hasattr(e, "headers") else {}
        try:    body = json.loads(raw)
        except: body = {"raw": raw}
        return e.code, body, hdr


def _bar(consumed: int, quota: int, width: int = 40) -> str:
    filled = min(width, math.ceil(consumed / quota * width)) if quota else 0
    pct    = min(100.0, consumed / quota * 100) if quota else 0
    bar    = "█" * filled + "░" * (width - filled)
    return f"[{bar}] {pct:5.1f}%"


# ── Argument parsing ──────────────────────────────────────────────────────────
def _arg(flag, default):
    for i, a in enumerate(sys.argv):
        if a == flag and i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default

def _flag(flag):
    return flag in sys.argv

N_REQUESTS = int(_arg("--requests", 5))
WAIT_SEC   = int(_arg("--wait", 65))
NO_WAIT    = _flag("--no-wait")


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    print("=" * 60)
    print("Fabrikam burst + quota persistence test")
    print("=" * 60)

    # Load Terraform outputs
    print("\nLoading Terraform outputs...")
    gateway     = _tf("apim_gateway_url")
    tenant_keys = _tf("apim_tenant_subscription_keys")
    tenant_cfg  = _tf("tenant_config")

    fabrikam_key   = tenant_keys[TENANT_SLUG]["primary_key"]
    cfg            = tenant_cfg[TENANT_SLUG]
    quota          = cfg["token_quota"]
    period         = cfg["token_quota_period"]
    tpm            = cfg["tokens_per_minute"]

    print(f"  Gateway  : {gateway}")
    print(f"  Tenant   : {cfg['display_name']}")
    print(f"  Quota    : {quota:,} tokens / {period}")
    print(f"  TPM cap  : {tpm:,} tokens/min")

    # ── Burst 1 ───────────────────────────────────────────────────────────────
    print()
    print("─" * 60)
    print(f"BURST 1 — {N_REQUESTS} request(s), {MAX_TOKENS} max_tokens each")
    print("─" * 60)

    run1_remaining = None
    cumulative     = 0

    for i in range(1, N_REQUESTS + 1):
        status, usage, headers = _chat(gateway, fabrikam_key, PROMPT, MAX_TOKENS)
        rq = headers.get("x-remaining-quota-tokens")
        rt = headers.get("x-remaining-tpm-tokens")

        if status == 200:
            used        = usage.get("total_tokens", 0)
            cumulative += used
            remaining   = int(rq) if rq is not None else None
            run1_remaining = remaining
            consumed_so_far = quota - remaining if remaining is not None else cumulative

            bar = _bar(consumed_so_far, quota) if remaining is not None else ""
            print(
                f"  Req {i}/{N_REQUESTS} | HTTP 200 | {used:>4} tok used | "
                f"Quota left: {remaining if remaining is not None else 'n/a':>7} | "
                f"TPM left: {int(rt) if rt else 'n/a':>6}  {bar}"
            )
        else:
            msg = ""
            if isinstance(usage, dict):
                msg = usage.get("message") or usage.get("error", {}).get("message", "")
            label = ("QUOTA EXHAUSTED" if "quota" in msg.lower()
                     else "RATE LIMITED"   if status == 429
                     else f"ERR-{status}")
            print(f"  Req {i}/{N_REQUESTS} | HTTP {status} | >> {label}")
            print(f"  Stopping burst — {label}.")
            break
        time.sleep(1)

    print(f"\n  Burst 1 done.  Cumulative this burst: {cumulative:,} tokens.")
    if run1_remaining is not None:
        print(f"  Quota remaining after Burst 1: {run1_remaining:,}")

    # ── Wait ──────────────────────────────────────────────────────────────────
    if NO_WAIT:
        print("\n  --no-wait: skipping pause (TPM counter may not have reset).")
    else:
        print()
        print("─" * 60)
        print(f"WAIT {WAIT_SEC}s — TPM window resets; hourly quota counter must persist")
        print("─" * 60)
        for remaining_w in range(WAIT_SEC, 0, -5):
            print(f"  {remaining_w:3d}s remaining...     ", end="\r")
            time.sleep(min(5, remaining_w))
        print("\n  Wait complete.")

    # ── Burst 2 (ping) ────────────────────────────────────────────────────────
    print()
    print("─" * 60)
    print("BURST 2 — single ping request to read persisted counter")
    print("─" * 60)

    status2, usage2, headers2 = _chat(gateway, fabrikam_key, PING_PROMPT, PING_MAX_TOKENS)
    rq2 = headers2.get("x-remaining-quota-tokens")
    rt2 = headers2.get("x-remaining-tpm-tokens")

    run2_remaining = int(rq2) if rq2 is not None else None
    used2 = usage2.get("total_tokens", 0) if isinstance(usage2, dict) and status2 == 200 else 0

    if status2 == 200:
        print(
            f"  HTTP 200 | {used2} tok | "
            f"Quota left: {run2_remaining if run2_remaining is not None else 'n/a'} | "
            f"TPM left: {int(rt2) if rt2 else 'n/a'}"
        )
    else:
        print(f"  HTTP {status2} | {usage2}")

    # ── Verdict ───────────────────────────────────────────────────────────────
    print()
    print("=" * 60)
    print("RESULT")
    print("=" * 60)

    if run1_remaining is None or run2_remaining is None:
        print("  INCONCLUSIVE — quota headers missing.")
        print("  Check that the APIM outbound policy sets x-remaining-quota-tokens.")
        sys.exit(1)

    delta = run1_remaining - run2_remaining   # positive = Run 2 consumed more (correct)
    pct1  = round((quota - run1_remaining) / quota * 100, 1)
    pct2  = round((quota - run2_remaining) / quota * 100, 1)
    threshold = 500

    print(f"  Burst 1 end : {run1_remaining:>8,} remaining  ({pct1:.1f}% consumed)")
    print(f"  Burst 2 end : {run2_remaining:>8,} remaining  ({pct2:.1f}% consumed)")
    print(f"  Delta       : {delta:>+8,} tokens (threshold: ±{threshold})")
    print()

    if abs(delta) <= threshold:
        print("  PASS ✓  Counter persisted across TPM window reset.")
        print("          Redis-backed hourly quota is working correctly.")
    else:
        print("  FAIL ✗  Counter jumped by more than threshold.")
        print("          The quota counter was NOT consistent between bursts.")
        print("          Possible cause: per-process counter; a different process/replica")
        print("          handled Burst 2 and had a fresh (uncommitted) counter.")
        sys.exit(2)

    print("=" * 60)


if __name__ == "__main__":
    main()
