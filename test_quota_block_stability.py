"""Verify an already-exhausted tenant remains blocked while another tenant remains usable.

Run this immediately after `test_streaming_quota_enforcement.py --enforce --tenant fabrikam`.
It intentionally does not infer quota state from remaining-quota headers. Instead it:

1. Sends repeated low-token probes to the exhausted Fabrikam subscription.
2. Requires quota HTTP 403 for every probe across the observation interval.
3. Sends a Contoso request and requires HTTP 200, proving tenant isolation.

Usage:
    python test_quota_block_stability.py
    python test_quota_block_stability.py --probes 4 --interval 25
"""

import json
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

EXHAUSTED_TENANT = "fabrikam"
ISOLATION_TENANT = "contoso"
DEPLOYMENT = "gpt-4o-mini"
API_VERSION = "2024-10-21"
_ssl_context = ssl.create_default_context()


def arg_value(flag, default):
    try:
        return int(sys.argv[sys.argv.index(flag) + 1])
    except (ValueError, IndexError):
        return default


def tf_output(name):
    result = subprocess.run(
        ["terraform", "output", "-json", name], capture_output=True, text=True
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


def call(endpoint, key, prompt):
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(
            {"messages": [{"role": "user", "content": prompt}], "max_tokens": 12}
        ).encode(),
        headers={"Content-Type": "application/json", "api-key": key},
    )
    try:
        with urllib.request.urlopen(request, context=_ssl_context, timeout=60) as response:
            body = json.loads(response.read())
            return response.status, body, dict(response.headers)
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8", "replace")
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            body = {"raw": raw}
        return error.code, body, dict(error.headers)


def quota_block(status, body):
    return status == 403 and "quota" in json.dumps(body).lower()


def main():
    probes = arg_value("--probes", 4)
    interval = arg_value("--interval", 25)
    gateway = tf_output("apim_gateway_url")
    keys = tf_output("apim_tenant_subscription_keys")
    endpoint = f"{gateway}/openai/deployments/{DEPLOYMENT}/chat/completions?api-version={API_VERSION}"

    print("=" * 72)
    print("APIM exhausted-quota stability and tenant-isolation regression")
    print("=" * 72)
    print(f"Exhausted tenant : {keys[EXHAUSTED_TENANT]['display_name']}")
    print(f"Isolation tenant : {keys[ISOLATION_TENANT]['display_name']}")
    print(f"Observation      : {probes} probes every {interval}s")

    failures = []
    for number in range(1, probes + 1):
        status, body, headers = call(
            endpoint,
            keys[EXHAUSTED_TENANT]["primary_key"],
            "Reply with exactly QUOTA-CHECK.",
        )
        print(f"Fabrikam probe {number}/{probes}: HTTP {status}")
        if not quota_block(status, body):
            failures.append(
                f"Fabrikam probe {number} was not a quota 403: {json.dumps(body)[:300]}"
            )
        if number < probes:
            time.sleep(interval)

    status, body, headers = call(
        endpoint,
        keys[ISOLATION_TENANT]["primary_key"],
        "Reply with exactly ISOLATED.",
    )
    print(f"Contoso isolation probe: HTTP {status}")
    if status != 200:
        failures.append(f"Contoso was unexpectedly blocked: {json.dumps(body)[:300]}")

    print("\n" + "=" * 72)
    if failures:
        print("FAIL")
        for failure in failures:
            print(f"  - {failure}")
        return 1

    print("PASS")
    print("  - The exhausted Fabrikam quota stayed blocked throughout the interval.")
    print("  - Contoso stayed available, confirming tenant isolation.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
