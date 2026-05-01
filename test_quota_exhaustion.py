"""

Quota-exhaustion demo for a single tenant (default: Fabrikam Inc).



Demonstrates the FULL exhaust-wait-recover cycle of the Redis-backed hourly

quota enforced inside the APIM policy:



  Phase 1 -- EXHAUST

    Send sequential requests, printing the remaining-quota countdown after each

    one.  When the quota drops to zero the next call returns HTTP 429 (too-many

    tokens) or HTTP 403 (quota exceeded), depending on which limit fires first.



  Phase 2 -- BLOCKED

    Prints a clear "QUOTA EXHAUSTED" banner that shows:

      * tokens consumed / total

      * exact UTC timestamp when the Redis key rotates (top of next hour)

      * countdown in mm:ss



  Phase 3 -- RECOVERY  (only with --watch)

    Waits until the hourly window rolls over, then fires one probe request to

    confirm the counter has reset and the tenant is back in service.



Configuration is loaded entirely from Terraform outputs -- no hardcoded secrets.



Usage

-----

    python test_quota_exhaustion.py                        # Fabrikam, exhaust then exit

    python test_quota_exhaustion.py --watch               # stay alive, verify full reset

    python test_quota_exhaustion.py --tenant fabrikam     # explicit tenant slug

    python test_quota_exhaustion.py --tenant adventure-works --watch



Quota settings (applied via terraform.tfvars -> APIM policy)

-------------------------------------------------------------

    Fabrikam:  2 000 TPM soft cap  |  5 000 tokens / hour hard quota

    ~6 requests x 800 tokens = quota exhausted inside one turn

"""

import json

import math

import ssl

import subprocess

import sys

import time

import urllib.request

import urllib.error

from datetime import datetime, timezone, timedelta



# --- CLI ---------------------------------------------------------------------



def _parse_args():

    args   = sys.argv[1:]

    tenant = "fabrikam"

    watch  = False

    i = 0

    while i < len(args):

        if args[i] == "--tenant" and i + 1 < len(args):

            tenant = args[i + 1]

            i += 2

        elif args[i] == "--watch":

            watch = True

            i += 1

        else:

            print(f"Unknown argument: {args[i]}")

            sys.exit(1)

    return tenant, watch



# --- Terraform helpers -------------------------------------------------------



def tf_output(name):

    result = subprocess.run(

        ["terraform", "output", "-json", name],

        capture_output=True, text=True,

    )

    if result.returncode != 0:

        print(f"ERROR: terraform output '{name}': {result.stderr.strip()}", file=sys.stderr)

        sys.exit(1)

    return json.loads(result.stdout)





def load_tenant(slug):

    """Return (gateway_url, api_key, display_name, quota_tokens, quota_period)."""

    gateway      = tf_output("apim_gateway_url")

    tenant_keys  = tf_output("apim_tenant_subscription_keys")

    tenant_cfg   = tf_output("tenant_config")          # map: slug -> {token_quota, ...}



    if slug not in tenant_keys:

        available = list(tenant_keys.keys())

        print(f"ERROR: tenant slug '{slug}' not found.  Available: {available}",

              file=sys.stderr)

        sys.exit(1)



    display_name = tenant_keys[slug]["display_name"]

    api_key      = tenant_keys[slug]["primary_key"]

    quota        = int(tenant_cfg[slug]["token_quota"])

    period       = tenant_cfg[slug]["token_quota_period"]   # "Hourly" | "Monthly"

    tpm          = int(tenant_cfg[slug]["tokens_per_minute"])



    return gateway, api_key, display_name, quota, period, tpm



# --- HTTP helper -------------------------------------------------------------



_ssl_ctx = ssl.create_default_context()



def chat(gateway, api_key, prompt, max_tokens=800):

    """POST /chat/completions.  Returns (status, usage_dict_or_error, response_headers)."""

    endpoint = (

        f"{gateway}/openai/deployments/gpt-4o-mini/chat/completions"

        "?api-version=2024-10-21"

    )

    payload = json.dumps({

        "messages": [{"role": "user", "content": prompt}],

        "max_tokens": max_tokens,

    }).encode()

    req = urllib.request.Request(endpoint, data=payload, headers={

        "Content-Type": "application/json",

        "api-key":      api_key,

    })

    try:

        with urllib.request.urlopen(req, context=_ssl_ctx, timeout=60) as resp:

            body = json.loads(resp.read())

            return resp.status, body.get("usage", {}), dict(resp.headers)

    except urllib.error.HTTPError as exc:

        raw     = exc.read().decode()

        headers = dict(exc.headers) if hasattr(exc, "headers") else {}

        try:

            body = json.loads(raw)

        except Exception:

            body = {"raw": raw}

        return exc.code, body, headers



# --- Time helpers ------------------------------------------------------------



def next_hour_utc():

    """Return the UTC datetime at the start of the next full hour."""

    now = datetime.now(timezone.utc)

    return (now + timedelta(hours=1)).replace(minute=0, second=0, microsecond=0)





def seconds_until(dt):

    return max(0, int((dt - datetime.now(timezone.utc)).total_seconds()))





def fmt_countdown(sec):

    m, s = divmod(sec, 60)

    return f"{m:02d}m {s:02d}s"



# --- Banner helpers ----------------------------------------------------------



WIDTH = 62



def banner_exhausted(display_name, consumed, quota, reset_at):

    rem = seconds_until(reset_at)

    lines = [

        "=" * WIDTH,

        f"  [X]  QUOTA EXHAUSTED  --  {display_name}",

        "-" * WIDTH,

        f"  Consumed : {consumed:,} / {quota:,} tokens",

        f"  Resets at: {reset_at.strftime('%H:%M:%S UTC')}  (in {fmt_countdown(rem)})",

        "=" * WIDTH,

    ]

    print()

    for line in lines:

        print(line)

    print()





def banner_recovered(display_name, remaining, quota):

    lines = [

        "=" * WIDTH,

        f"  [OK] QUOTA RESET  --  {display_name}",

        "-" * WIDTH,

        f"  Fresh quota : {remaining:,} / {quota:,} tokens available",

        "=" * WIDTH,

    ]

    print()

    for line in lines:

        print(line)

    print()



# --- Main demo ---------------------------------------------------------------



PROMPT = (

    "List exactly ten interesting facts about the Python programming language. "

    "Number each fact, and write 2-3 sentences per fact."

)





def run_demo(tenant_slug, watch):

    print()

    print("+" + "=" * (WIDTH - 2) + "+")

    print("|  AI Gateway -- Quota Exhaustion Demo" + " " * (WIDTH - 38) + "|")

    print("+" + "=" * (WIDTH - 2) + "+")



    print("\nLoading config from Terraform outputs...")

    gateway, api_key, display_name, quota, period, tpm = load_tenant(tenant_slug)



    expected_requests = math.ceil(quota / 800)



    print(f"\n  Tenant  : {display_name}  ({tenant_slug})")

    print(f"  Gateway : {gateway}")

    print(f"  Quota   : {quota:,} tokens / {period}")

    print(f"  TPM cap : {tpm:,} tokens / minute")

    print(f"  Expect  : ~{expected_requests} requests before exhaustion")

    if period == "Hourly":

        reset_at = next_hour_utc()

        print(f"  Resets  : {reset_at.strftime('%H:%M:%S UTC')}  ({fmt_countdown(seconds_until(reset_at))} from now)")



    # -- Phase 1: exhaust ----------------------------------------------------

    print()

    print("-" * WIDTH)

    print("  Phase 1 -- Sending requests until quota exhausted")

    print("-" * WIDTH)

    print(f"  {'Req':>3}  {'Status':>6}  {'Tokens':>7}  {'Remaining':>12}  {'TPM Left':>10}")

    print(f"  {'---':>3}  {'------':>6}  {'-------':>7}  {'---------':>12}  {'--------':>10}")



    req_num       = 0

    total_tokens  = 0

    exhausted     = False

    throttled     = False



    while True:

        req_num += 1

        status, body, headers = chat(gateway, api_key, PROMPT, max_tokens=800)



        remaining_quota = headers.get("x-remaining-quota-tokens", "n/a")

        remaining_tpm   = headers.get("x-remaining-tpm-tokens",   "n/a")



        if status == 200:

            used          = body.get("total_tokens", 0)

            total_tokens += used

            print(

                f"  {req_num:>3}  {status:>6}  {used:>7,}  "

                f"{remaining_quota:>12}  {remaining_tpm:>10}"

            )

            # Natural end: remaining header reports 0 or negative

            try:

                if int(remaining_quota) <= 0:

                    exhausted    = True

                    total_tokens = quota

                    break

            except (ValueError, TypeError):

                pass

        elif status == 429:

            throttled = True

            # Parse remaining from error body if present

            remaining_quota = headers.get("x-remaining-quota-tokens", "0")

            remaining_tpm   = headers.get("x-remaining-tpm-tokens",   "0")

            msg = ""

            if isinstance(body, dict):

                msg = (body.get("message") or

                       body.get("error", {}).get("message", ""))

            print(

                f"  {req_num:>3}  {status:>6}  "

                f"{'TPM/Quota':>7}  "

                f"{remaining_quota:>12}  {remaining_tpm:>10}"

                f"  <- {msg[:40]}"

            )

            # Check whether this is a quota block or just TPM

            if "quota" in msg.lower() or remaining_quota in ("0", ""):

                exhausted    = True

                total_tokens = quota

            else:

                # Just a TPM rate-limit hit -- wait a moment and retry

                wait_sec = 10

                retry_after = headers.get("retry-after") or headers.get("x-ms-retry-after-ms")

                if retry_after:

                    try:

                        wait_sec = max(1, int(retry_after) // 1000 if "ms" in (retry_after or "") else int(retry_after))

                    except ValueError:

                        pass

                print(f"       (TPM limit -- waiting {wait_sec}s before next request)")

                time.sleep(wait_sec)

                continue

            break

        else:

            # 403 or other hard block

            exhausted = True

            msg = ""

            if isinstance(body, dict):

                msg = (body.get("message") or

                       body.get("error", {}).get("message", ""))

            print(

                f"  {req_num:>3}  {status:>6}  "

                f"{'BLOCKED':>7}  "

                f"{remaining_quota:>12}  {remaining_tpm:>10}"

                f"  <- {msg[:40]}"

            )

            total_tokens = quota

            break



        # Safety cap -- avoid infinite loops if headers are missing

        if req_num >= 50:

            print("  (safety limit reached -- stopping)")

            break



    # -- Phase 2: exhausted banner -------------------------------------------

    if exhausted or throttled:

        reset_at = next_hour_utc() if period == "Hourly" else None

        consumed = total_tokens



        if reset_at:

            banner_exhausted(display_name, consumed, quota, reset_at)

        else:

            print()

            print("=" * WIDTH)

            print(f"  [X]  QUOTA EXHAUSTED  --  {display_name}")

            print(f"  Consumed : {consumed:,} / {quota:,} tokens")

            print(f"  Note     : {period} quota -- no hourly reset available.")

            print("=" * WIDTH)

            print()

    else:

        print("\n  (quota was not exhausted after all requests)")

        return



    # -- Phase 3: wait for reset (--watch) ----------------------------------

    if not watch or period != "Hourly" or reset_at is None:

        if watch and period != "Hourly":

            print(f"  Note: --watch is only meaningful for Hourly quotas.  "

                  f"Current period: {period}")

        return



    print("-" * WIDTH)

    print("  Phase 3 -- Waiting for hourly quota reset (--watch mode)")

    print("-" * WIDTH)



    last_printed = -1

    while True:

        rem = seconds_until(reset_at)

        if rem <= 0:

            break

        # Print countdown every 15 seconds

        bucket = rem // 15

        if bucket != last_printed:

            last_printed = bucket

            print(f"  [{datetime.now(timezone.utc).strftime('%H:%M:%S')} UTC]  "

                  f"Reset in {fmt_countdown(rem)} ...")

        time.sleep(5)



    # Give APIM a moment to propagate the new Redis key

    print("  Hourly window rotated.  Waiting 5 s for propagation ...")

    time.sleep(5)



    # Probe request in the new window

    print("  Sending probe request ...")

    status, body, headers = chat(gateway, api_key, "Say 'quota reset' in one word.", max_tokens=20)

    remaining_quota = headers.get("x-remaining-quota-tokens", "?")



    if status == 200:

        try:

            remaining_int = int(remaining_quota)

        except (ValueError, TypeError):

            remaining_int = quota

        banner_recovered(display_name, remaining_int, quota)

    else:

        msg = ""

        if isinstance(body, dict):

            msg = body.get("message") or body.get("error", {}).get("message", "")

        print(f"  Probe returned HTTP {status}: {msg}")

        print("  The quota may not have reset yet -- try again in a few seconds.")





if __name__ == "__main__":

    tenant_slug, watch = _parse_args()

    run_demo(tenant_slug, watch)

