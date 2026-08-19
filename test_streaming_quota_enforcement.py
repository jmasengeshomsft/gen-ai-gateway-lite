"""Test native APIM streaming quota enforcement without trusting quota headers as a ledger.

Why this test exists
--------------------
`remaining-quota-tokens` is documented by APIM as an estimate. It can change
while a request is being processed and is not an authoritative post-stream
balance. This test therefore verifies behavior instead of calculating a balance
from response headers:

1. Send sequential streaming requests for a tenant until APIM returns a quota
   HTTP 403.
2. Wait longer than a TPM window (70 seconds) but shorter than the tenant's
   hourly quota window.
3. Send another request and require it to still return quota HTTP 403.

A 429 is treated as expected TPM protection. The test waits for the indicated
retry period and continues. All streaming requests request terminal usage with
`stream_options.include_usage=true` and consume their SSE streams completely.

Usage
-----
  # Low-impact connectivity and SSE check only (default)
  python test_streaming_quota_enforcement.py

  # Destructive enforcement regression: consumes Fabrikam's 5K hourly allowance
  python test_streaming_quota_enforcement.py --enforce --tenant fabrikam

The `--enforce` mode can consume most of the selected tenant's active quota.
"""

import json
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

TENANT = "fabrikam"
DEPLOYMENT = "gpt-4o-mini"
API_VERSION = "2024-10-21"
TPM_WAIT_SECONDS = 70
MAX_ATTEMPTS = 16
MAX_TOKENS = 800
_ssl_context = ssl.create_default_context()


def arg_value(flag, default):
    try:
        return sys.argv[sys.argv.index(flag) + 1]
    except (ValueError, IndexError):
        return default


def tf_output(name):
    result = subprocess.run(
        ["terraform", "output", "-json", name], capture_output=True, text=True
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


def send_stream(endpoint, api_key, prompt, max_tokens):
    request_id = str(uuid.uuid4())
    body = {
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "api-key": api_key,
            "x-ms-client-request-id": request_id,
        },
    )

    try:
        with urllib.request.urlopen(request, context=_ssl_context, timeout=120) as response:
            chunks = 0
            content_chunks = 0
            usage = None
            done = False
            for raw in response:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                chunks += 1
                data = line[5:].strip()
                if data == "[DONE]":
                    done = True
                    continue
                event = json.loads(data)
                usage = event.get("usage") or usage
                content_chunks += sum(
                    1
                    for choice in event.get("choices", [])
                    if choice.get("delta", {}).get("content")
                )
            return {
                "status": response.status,
                "headers": dict(response.headers),
                "usage": usage,
                "chunks": chunks,
                "content_chunks": content_chunks,
                "done": done,
                "request_id": request_id,
            }
    except urllib.error.HTTPError as error:
        raw = error.read().decode("utf-8", "replace")
        try:
            body = json.loads(raw)
        except json.JSONDecodeError:
            body = {"raw": raw}
        return {
            "status": error.code,
            "headers": dict(error.headers),
            "body": body,
            "chunks": 0,
            "content_chunks": 0,
            "done": False,
            "request_id": request_id,
        }


def is_quota_block(result):
    if result["status"] != 403:
        return False
    body = result.get("body", {})
    text = json.dumps(body).lower()
    return "quota" in text or "tokenquotaexceeded" in text


def retry_seconds(result):
    value = result["headers"].get("Retry-After") or result["headers"].get("retry-after")
    try:
        return max(1, min(int(value), TPM_WAIT_SECONDS))
    except (TypeError, ValueError):
        return TPM_WAIT_SECONDS


def summary(result):
    headers = {key.lower(): value for key, value in result["headers"].items()}
    return (
        f"HTTP {result['status']} | chunks={result['chunks']} | "
        f"usage={(result.get('usage') or {}).get('total_tokens', 'n/a')} | "
        f"TPM header={headers.get('x-remaining-tpm-tokens', 'n/a')} | "
        f"quota header={headers.get('x-remaining-quota-tokens', 'n/a')}"
    )


def main():
    enforce = "--enforce" in sys.argv
    tenant_slug = arg_value("--tenant", TENANT)
    gateway = tf_output("apim_gateway_url")
    tenant_keys = tf_output("apim_tenant_subscription_keys")
    tenant_config = tf_output("tenant_config")

    if tenant_slug not in tenant_keys or tenant_slug not in tenant_config:
        raise RuntimeError(f"Unknown tenant '{tenant_slug}'")

    tenant = tenant_config[tenant_slug]
    endpoint = f"{gateway}/openai/deployments/{DEPLOYMENT}/chat/completions?api-version={API_VERSION}"
    api_key = tenant_keys[tenant_slug]["primary_key"]

    print("=" * 72)
    print("APIM streaming quota enforcement regression")
    print("=" * 72)
    print(f"Tenant       : {tenant_keys[tenant_slug]['display_name']}")
    print(f"Configured  : {tenant['token_quota']} tokens / {tenant['token_quota_period']}")
    print(f"TPM          : {tenant['tokens_per_minute']}")
    print(f"Mode         : {'ENFORCEMENT (quota-consuming)' if enforce else 'SSE smoke'}")

    if not enforce:
        result = send_stream(endpoint, api_key, "Reply with exactly STREAMING-OK.", 12)
        print("\nSSE smoke:", summary(result))
        if (
            result["status"] == 200
            and result["chunks"] > 0
            and result["content_chunks"] > 0
            and result["done"]
            and (result.get("usage") or {}).get("total_tokens", 0) > 0
        ):
            print("PASS: unbuffered SSE and terminal usage are available.")
            return 0
        print("FAIL: streaming response did not meet the SSE contract.")
        return 1

    if tenant["token_quota_period"] != "Hourly":
        print("FAIL: --enforce is intentionally restricted to an Hourly test tenant.")
        return 2

    quota_block = None
    for attempt in range(1, MAX_ATTEMPTS + 1):
        result = send_stream(
            endpoint,
            api_key,
            "Write a detailed technical essay about cloud-native AI infrastructure, "
            "including networking, identity, observability, quotas, and resiliency.",
            MAX_TOKENS,
        )
        print(f"Attempt {attempt:02d}: {summary(result)}")

        if result["status"] == 200:
            if not (result["chunks"] and result["content_chunks"] and result["done"]):
                print("FAIL: a successful response was not valid SSE.")
                return 1
            continue
        if is_quota_block(result):
            quota_block = result
            print("\nQuota block observed before the hourly boundary.")
            break
        if result["status"] == 429:
            wait = retry_seconds(result)
            print(f"TPM block expected; waiting {wait}s before retrying.")
            time.sleep(wait)
            continue

        print(f"FAIL: unexpected error: {result.get('body')}")
        return 1

    if quota_block is None:
        print("FAIL: quota was not enforced within the configured attempt budget.")
        return 1

    print(f"\nWaiting {TPM_WAIT_SECONDS}s to cross a TPM window without crossing the hourly quota window...")
    time.sleep(TPM_WAIT_SECONDS)
    probe = send_stream(endpoint, api_key, "Reply with exactly QUOTA-PROBE.", 12)
    print("Post-TPM probe:", summary(probe))

    if is_quota_block(probe):
        print("PASS: quota remained enforced after the TPM window reset.")
        return 0

    print("FAIL: quota block disappeared before the hourly quota boundary.")
    print("This reproduces the quota-reset symptom independently of the estimate header.")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        sys.exit(1)
