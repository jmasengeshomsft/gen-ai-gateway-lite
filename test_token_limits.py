"""
Test per-tenant token limits across both APIM instances.

Dynamically loads APIM gateway URLs and subscription keys from Terraform outputs.
No hardcoded secrets — uses your local `az login` session.

Gateway versions
----------------
  --gateway v2    StandardV2 (ACA-backed, multi-replica counters)  [default]
  --gateway v1    Classic Developer_1 (single VM, single counter)
  --gateway both  Run all phases against v1 AND v2; side-by-side quota comparison

Usage examples
--------------
    python test_token_limits.py                                        # v2 only, all phases
    python test_token_limits.py --gateway v1                          # v1 only
    python test_token_limits.py --gateway both                        # v1 + v2 comparison
    python test_token_limits.py --burst fabrikam                      # burst-test on v2
    python test_token_limits.py --burst fabrikam --gateway both       # burst on both
    python test_token_limits.py --quota-proof fabrikam                # quota proof on v2
    python test_token_limits.py --quota-proof fabrikam --gateway both # side-by-side proof

Counter behaviour under test
-----------------------------
  Both v1 and v2 exhibit the same fundamental behaviour as documented by
  Microsoft (https://learn.microsoft.com/en-us/azure/api-management/llm-token-limit-policy):

    "This policy tracks token usage independently at each gateway where it is
     applied... It doesn't aggregate token counts across the entire instance."

  In other words, llm-token-limit counters are per-process by design and do NOT
  use the APIM external Redis cache (which only applies to rate-limit / quota /
  cache-lookup-value policies).

  v2 (StandardV2): ACA scales to multiple gateway replicas.  Each replica has its
    own independent llm-token-limit counter.  Without a shared store, round-robin
    routing causes diverging quota values.

  v1 (Classic Developer_1): single VM but multiple IIS worker processes (typically
    2-3).  Each worker process has its own independent llm-token-limit counter.

  Fix (implemented): quota enforcement is handled by a custom Redis counter using
  cache-lookup-value / cache-store-value with caching-type="external".  All processes
  and replicas read from and write to the same Redis key, so the quota counter is
  globally consistent.  llm-token-limit is retained for TPM rate limiting only.
"""
import urllib.request
import json
import ssl
import sys
import time
import subprocess
import concurrent.futures
import threading

# ─── Terraform output helpers ─────────────────────────────────────────────────

def tf_output(name):
    """Fetch a Terraform output value using the local az login session."""
    result = subprocess.run(
        ["terraform", "output", "-json", name],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"ERROR: terraform output '{name}': {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return json.loads(result.stdout)


def load_config(version="v2"):
    """Load APIM gateway URL + all subscription keys for the given version."""
    if version == "v1":
        gw_out          = "apim_v1_gateway_url"
        default_key_out = "apim_v1_subscription_key"
        tenant_keys_out = "apim_v1_tenant_subscription_keys"
        label           = "v1 (Classic Developer_1)"
    else:
        gw_out          = "apim_gateway_url"
        default_key_out = "apim_subscription_key"
        tenant_keys_out = "apim_tenant_subscription_keys"
        label           = "v2 (StandardV2)"

    print(f"  Loading APIM {label} config from Terraform outputs...")
    gateway     = tf_output(gw_out)
    default_key = tf_output(default_key_out)
    tenant_keys = tf_output(tenant_keys_out)

    subscriptions = {
        "Default (Lab)": {"key": default_key},
    }
    for slug, info in tenant_keys.items():
        subscriptions[info["display_name"]] = {
            "key":  info["primary_key"],
            "slug": slug,
        }

    print(f"  Gateway:       {gateway}")
    print(f"  Subscriptions: {', '.join(subscriptions.keys())}")
    return gateway, subscriptions, label


# ─── HTTP helper ──────────────────────────────────────────────────────────────

_ssl_ctx    = ssl.create_default_context()
_print_lock = threading.Lock()


def chat(gateway, api_key, prompt, max_tokens=100):
    """Send a chat completions request; returns (status, usage, content[:80], headers)."""
    endpoint = (
        f"{gateway}/openai/deployments/gpt-4o-mini/chat/completions"
        "?api-version=2024-10-21"
    )
    data = json.dumps({
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
    }).encode()
    req = urllib.request.Request(endpoint, data=data, headers={
        "Content-Type": "application/json",
        "api-key":      api_key,
    })
    try:
        with urllib.request.urlopen(req, context=_ssl_ctx, timeout=60) as resp:
            body = json.loads(resp.read())
            return (
                resp.status,
                body.get("usage", {}),
                body["choices"][0]["message"]["content"][:80],
                dict(resp.headers),
            )
    except urllib.error.HTTPError as e:
        raw     = e.read().decode()
        headers = dict(e.headers) if hasattr(e, "headers") else {}
        try:
            return e.code, json.loads(raw), None, headers
        except Exception:
            return e.code, raw, None, headers


# ─── Phase 1: baseline smoke-test across all subscriptions ────────────────────

def phase1(gateway, subscriptions, label):
    print()
    print("=" * 70)
    print(f"PHASE 1 [{label}]: Chat completions across all subscriptions")
    print("=" * 70)
    for name, info in subscriptions.items():
        status, usage, content, headers = chat(
            gateway, info["key"],
            f"Tell me one fun fact about {name} in 1 sentence.",
        )
        remaining_tpm   = headers.get("x-remaining-tpm-tokens",   "n/a")
        remaining_quota = headers.get("x-remaining-quota-tokens",  "n/a")
        if status == 200:
            print(
                f"  OK {name:22s} | HTTP {status} | "
                f"{usage.get('total_tokens','?'):>4} tokens | "
                f"TPM left: {remaining_tpm:>8} | Quota left: {remaining_quota}"
            )
        else:
            print(f"  !! {name:22s} | HTTP {status} | {usage}")
        time.sleep(0.3)


# ─── Phase 2: concurrent burst ────────────────────────────────────────────────

def phase2(gateway, subscriptions, label, burst_hint=""):
    """Burst 10 concurrent requests at the target tenant; return the burst target name."""
    # resolve burst target
    burst_target = None
    if burst_hint:
        burst_target = next(
            (n for n in subscriptions if burst_hint.lower() in n.lower()), None
        )
        if not burst_target:
            print(f"  ERROR: No subscription matching '{burst_hint}'", file=sys.stderr)
            sys.exit(1)
    if not burst_target:
        burst_target = next(
            (n for n in subscriptions if n != "Default (Lab)"),
            list(subscriptions.keys())[0],
        )

    burst_key = subscriptions[burst_target]["key"]
    print()
    print("=" * 70)
    print(f"PHASE 2 [{label}]: CONCURRENT burst on {burst_target}")
    print(f"  Sending 10 parallel requests with max_tokens=800 each")
    print("=" * 70)

    results = []
    rate_limited = False

    def _send(i):
        prompt = (
            f"Request {i}: Write a comprehensive essay about artificial intelligence "
            "covering machine learning, deep learning, neural networks, NLP, computer "
            "vision, reinforcement learning, generative AI, and transformers."
        )
        return i, chat(gateway, burst_key, prompt, max_tokens=800)

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as executor:
        futures = [executor.submit(_send, i) for i in range(1, 11)]
        for future in concurrent.futures.as_completed(futures):
            i, (status, usage, content, headers) = future.result()
            remaining_quota = headers.get("x-remaining-quota-tokens", "n/a")
            if status == 200:
                tokens = usage.get("total_tokens", 0)
                with _print_lock:
                    print(f"  Req {i:2d}: HTTP {status} | {tokens:>4} tokens | Quota left: {remaining_quota}")
                results.append(("ok", tokens))
            elif status == 429:
                with _print_lock:
                    print(f"  Req {i:2d}: HTTP 429 >>> RATE LIMITED!")
                    if isinstance(usage, dict):
                        msg = usage.get("error", {}).get("message", str(usage))[:120]
                        print(f"           {msg}")
                results.append(("429", 0))
                rate_limited = True
            else:
                with _print_lock:
                    print(f"  Req {i:2d}: HTTP {status}")
                results.append(("err", 0))

    ok_count    = sum(1 for r in results if r[0] == "ok")
    lim_count   = sum(1 for r in results if r[0] == "429")
    total_tokens = sum(r[1] for r in results)
    print(f"\n  Summary: {ok_count} succeeded, {lim_count} rate-limited, {total_tokens} total tokens")
    if rate_limited:
        print("  >>> Token limit policy is WORKING!")
    else:
        print("  >>> No 429s in 10 parallel requests — sending 10 more sequentially...")
        for i in range(11, 21):
            status, usage, content, headers = chat(
                gateway, burst_key,
                f"Essay {i} about cloud computing and AI.", max_tokens=800,
            )
            if status == 200:
                tokens = usage.get("total_tokens", 0)
                total_tokens += tokens
                remaining_quota = headers.get("x-remaining-quota-tokens", "n/a")
                print(
                    f"  Req {i:2d}: HTTP {status} | {tokens:>4} tokens | "
                    f"Cumulative: {total_tokens} | Quota left: {remaining_quota}"
                )
            elif status == 429:
                print(f"  Req {i:2d}: HTTP 429 >>> RATE LIMITED after {total_tokens} total tokens!")
                break
            else:
                print(f"  Req {i:2d}: HTTP {status}")
                break

    return burst_target


# ─── Phase 3: cross-tenant isolation ─────────────────────────────────────────

def phase3(gateway, subscriptions, label, burst_target):
    isolation_target = next(
        (n for n in subscriptions if n != burst_target and n != "Default (Lab)"),
        "Default (Lab)",
    )
    print()
    print("=" * 70)
    print(f"PHASE 3 [{label}]: Cross-tenant isolation ({isolation_target} should still work)")
    print("=" * 70)
    status, usage, content, headers = chat(
        gateway, subscriptions[isolation_target]["key"], "Say hello in German.",
    )
    if status == 200:
        print(f"  OK {isolation_target} | HTTP {status} | {usage.get('total_tokens','?')} tokens | {content}")
        print(f"  >>> Isolation confirmed: {burst_target} throttled, {isolation_target} unaffected")
    else:
        print(f"  !! {isolation_target} | HTTP {status}")


# ─── Quota persistence proof ──────────────────────────────────────────────────
#
# Run 1 : 6 sequential requests (~1 000 tokens each) → consume ~12% of Fabrikam's
#          50 000 token/month quota.  Record remaining quota after last success.
# Wait  : WAIT_SECONDS (> 1 TPM window) so the per-minute counter resets.
#          The monthly quota counter does NOT reset — unless the APIM instance
#          was restarted or a new replica took over with a fresh counter.
# Run 2 : one tiny request.  Check that remaining quota ≈ Run 1's end value.
#
# Expected results (Redis-backed custom counter)
# ------------------------------------------------
#   Both v1 and v2 : Redis key shared across all processes/replicas.
#                    Run 2 reads the same counter Run 1 left off at.
#                    Delta = only the one tiny Run 2 request → PASS (delta < 500)

WAIT_SECONDS = 70   # just over one TPM window; keeps ACA warm (< 8 min idle)


def run_quota_proof(gateway, subscriptions, target_name, label):
    """Run the quota persistence proof for target_name; returns a result dict."""
    target = next((n for n in subscriptions if target_name.lower() in n.lower()), None)
    if not target:
        print(f"ERROR: No subscription matching '{target_name}'", file=sys.stderr)
        sys.exit(1)
    key = subscriptions[target]["key"]

    print()
    print("=" * 70)
    print(f"QUOTA PROOF [{label}]  —  {target}")
    print("=" * 70)
    print("\nRun 1: 6 requests × ~1 000 tokens  (target ~12 % of 50 000 monthly quota)...")

    run1_tokens    = 0
    run1_remaining = None
    for i in range(1, 7):
        status, usage, content, hdrs = chat(
            gateway, key,
            "Write a detailed technical essay about cloud-native AI infrastructure.",
            max_tokens=800,
        )
        remaining = hdrs.get("x-remaining-quota-tokens", "n/a")
        if status == 200:
            t = usage.get("total_tokens", 0)
            run1_tokens   += t
            run1_remaining = remaining
            print(f"  Req {i}: HTTP 200 | {t:>4} tokens | Quota remaining: {remaining}")
        else:
            print(f"  Req {i}: HTTP {status} — {usage}")
            break
        time.sleep(1)

    print(f"\n  Run 1 done.  ~{run1_tokens} tokens consumed.  Quota remaining: {run1_remaining}")
    print(
        f"  Waiting {WAIT_SECONDS}s — TPM window will reset; "
        "quota counter persists only if counter lives in a single process..."
    )
    for w in range(WAIT_SECONDS, 0, -10):
        print(f"    {w}s remaining...", end="\r")
        time.sleep(min(10, w))
    print()

    print("\nRun 2: one small request to read current quota counter...")
    status, usage, content, hdrs = chat(gateway, key, "Say hello.", max_tokens=20)
    run2_remaining = hdrs.get("x-remaining-quota-tokens", "n/a")
    print(f"  HTTP {status} | Quota remaining: {run2_remaining}")

    result = {
        "label":          label,
        "target":         target,
        "run1_tokens":    run1_tokens,
        "run1_remaining": run1_remaining,
        "run2_remaining": run2_remaining,
        "diff":           None,
        "pass":           None,
    }
    try:
        r1, r2 = int(run1_remaining), int(run2_remaining)
        diff          = abs(r1 - r2)
        result["diff"] = diff
        result["pass"] = diff < 500    # tolerate one small request delta
    except (ValueError, TypeError):
        pass
    return result


def _print_proof_result(r):
    print()
    print("─" * 70)
    r1s, r2s = r["run1_remaining"], r["run2_remaining"]
    if r["diff"] is None:
        print(f"  INFO  [{r['label']}]  Could not parse quota headers.")
        print(f"        Run1={r1s}  Run2={r2s}")
        print("        Check that the outbound policy sets x-remaining-quota-tokens.")
    else:
        r1i, r2i = int(r1s), int(r2s)
        verdict = "PASS ✓" if r["pass"] else "FAIL ✗"
        print(f"  {verdict}  [{r['label']}]")
        print(f"  Run 1 end   : {r1i:>10,} remaining")
        print(f"  Run 2 start : {r2i:>10,} remaining   (delta: {r1i - r2i:+,})")
        if r["pass"]:
            print("  Counter is consistent — single-process quota tracking confirmed.")
        else:
            print(
                f"  Delta {r['diff']:,} > threshold 500.\n"
                "  Counter diverged — Run 2 hit a process with a higher remaining quota.\n"
                "  llm-token-limit counters are per-process (IIS worker on Classic,\n"
                "  ACA replica on StandardV2) — not globally consistent across processes."
            )
    print("─" * 70)


# ─── Argument parsing ─────────────────────────────────────────────────────────

def _get_arg(flag, default=None):
    """Return the value after --flag, or default if absent."""
    for i, a in enumerate(sys.argv):
        if a == flag and i + 1 < len(sys.argv):
            return sys.argv[i + 1]
    return default


def _has_flag(flag):
    return flag in sys.argv


# ─── Main ─────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    gateway_arg   = _get_arg("--gateway", "v2")      # v1 | v2 | both
    burst_hint    = _get_arg("--burst",   "")
    quota_target  = _get_arg("--quota-proof", None)

    if gateway_arg not in ("v1", "v2", "both"):
        print(f"ERROR: --gateway must be v1, v2, or both (got '{gateway_arg}')", file=sys.stderr)
        sys.exit(1)

    versions = ["v1", "v2"] if gateway_arg == "both" else [gateway_arg]

    # ── Load configs ──────────────────────────────────────────────────────────
    print("=" * 70)
    print("Loading Terraform outputs (uses your az login session)...")
    print("=" * 70)
    configs = {}  # version → (gateway, subscriptions, label)
    for v in versions:
        configs[v] = load_config(v)

    # ── Phases 1-3 for each gateway ───────────────────────────────────────────
    last_burst_target = {}
    for v in versions:
        gw, subs, lbl = configs[v]
        phase1(gw, subs, lbl)
        bt = phase2(gw, subs, lbl, burst_hint)
        phase3(gw, subs, lbl, bt)
        last_burst_target[v] = bt

    print("\nDone — basic phases complete.")

    # ── Quota persistence proof ───────────────────────────────────────────────
    if quota_target:
        proof_results = []
        for v in versions:
            gw, subs, lbl = configs[v]
            r = run_quota_proof(gw, subs, quota_target, lbl)
            _print_proof_result(r)
            proof_results.append(r)

        if len(proof_results) == 2:
            # Side-by-side comparison summary
            print()
            print("=" * 70)
            print("SIDE-BY-SIDE COMPARISON")
            print("=" * 70)
            header = f"  {'Metric':<30} {'v1 (Classic)':>20}    {'v2 (StandardV2)':>20}"
            print(header)
            print("  " + "-" * (len(header) - 2))

            def _safe(val, fmt=">20"):
                return format(str(val), fmt)

            rv1, rv2 = proof_results[0], proof_results[1]
            rows = [
                ("Run 1 tokens consumed",  rv1["run1_tokens"],    rv2["run1_tokens"]),
                ("Quota after Run 1",       rv1["run1_remaining"], rv2["run1_remaining"]),
                ("Quota after Run 2",       rv1["run2_remaining"], rv2["run2_remaining"]),
                ("Delta (|R1-end − R2|)",   rv1["diff"],           rv2["diff"]),
                ("Result",
                    ("PASS ✓" if rv1["pass"] else "FAIL ✗") if rv1["pass"] is not None else "?",
                    ("PASS ✓" if rv2["pass"] else "FAIL ✗") if rv2["pass"] is not None else "?",
                ),
            ]
            for label_text, v1_val, v2_val in rows:
                print(f"  {label_text:<30} {str(v1_val):>20}    {str(v2_val):>20}")

            print()
            print("  INTERPRETATION")
            print("  " + "-" * 50)
            if rv1["pass"] and not rv2["pass"]:
                print("  v1 PASS / v2 FAIL  → Confirms per-replica counter fragmentation")
                print("  in StandardV2.  Classic single-VM counter is globally consistent.")
            elif rv1["pass"] and rv2["pass"]:
                print("  Both PASS  → v2 requests landed on the same replica both times.")
                print("  Re-run --quota-proof to get a more conclusive sample.")
            elif not rv1["pass"] and not rv2["pass"]:
                print("  Both FAIL  → Per-process llm-token-limit fragmentation confirmed on BOTH tiers.")
                print("  Classic APIM: multiple IIS worker processes per VM, each with an independent")
                print("  in-memory counter.  StandardV2: multiple ACA replicas, same problem.")
                print("  Redis external cache does NOT fix this — it is not used by llm-token-limit.")
                print("  Fix: implement a Redis-backed custom counter with cache-store-value /")
                print("  cache-lookup-value policies to achieve cross-process consistency.")
            else:
                print("  Unexpected result — check gateway health and retry.")
            print("=" * 70)

        sys.exit(0)

