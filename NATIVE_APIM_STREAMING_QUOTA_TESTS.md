# Native APIM streaming and token quota validation

This branch uses APIM's native `llm-token-limit` policy for per-tenant TPM and token-period quota enforcement. It does not use the optional Redis cache for quota enforcement.

## Policy model

- `llm-token-limit` enforces `tokens-per-minute` and `token-quota` per APIM subscription.
- `buffer-response="false"` forwards server-sent event (SSE) chunks immediately.
- `ApiManagementGatewayLlmLog` records the exact token usage after a streamed request completes when `stream_options.include_usage=true`.
- `x-remaining-quota-tokens` is a native APIM estimate. It is useful for diagnostics but is not the pass/fail source for quota enforcement tests.

## Test matrix

| Test | Command | Expected proof |
|---|---|---|
| Direct tenant smoke and isolation | `python test_token_limits.py` | Tenant subscriptions can call the gateway and are isolated under load. |
| SSE contract | `python test_streaming_quota_enforcement.py` | SSE chunks, content, `[DONE]`, and final stream usage are returned. |
| Streaming quota persistence | `python test_streaming_quota_enforcement.py --enforce --tenant fabrikam` | Fabrikam reaches a native hourly quota `403` and remains blocked after a TPM window passes. This consumes the hourly Fabrikam allowance. |
| Block stability and isolation | `python test_quota_block_stability.py --probes 4 --interval 25` | A quota-blocked Fabrikam remains blocked over the observation period while Contoso remains available. Run immediately after the enforcement test. |

## Interpretation

A quota test passes based on enforcement behavior:

1. The tenant receives HTTP `403` for an exhausted token quota.
2. The tenant remains blocked after waiting longer than a TPM window but before the quota period boundary.
3. Other tenants remain available.

Do not infer a quota reset only because `x-remaining-quota-tokens` increases. APIM documents that remaining quota is an estimate, particularly for concurrent and streaming requests.

## Current topology assumption

The native policy is suitable for this lab's single StandardV2 APIM instance in one East US region. If a future deployment needs one authoritative quota across multiple APIM regions, workspace gateways, self-hosted gateways, or APIM instances, use a centralized quota service with atomic counter operations.
