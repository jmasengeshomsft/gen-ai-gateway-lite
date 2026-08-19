# Native APIM streaming and token quota validation

This branch uses APIM's native `llm-token-limit` policy for per-tenant TPM and token-period quota enforcement. Redis-backed quota work is excluded from this focused branch so streaming and native APIM enforcement can be evaluated independently.

## What changed

The original policy used a custom quota counter implemented with APIM cache policies:

```xml
<cache-lookup-value key="@((string)context.Variables[&quot;tenantQuotaKey&quot;])"
					variable-name="quotaConsumed"
					caching-type="external"
					default-value="0" />

<!-- reject if quotaConsumed >= tenantQuotaLimit -->

<cache-lookup-value key="@((string)context.Variables[&quot;tenantQuotaKey&quot;])"
					variable-name="quotaConsumedCurrent"
					caching-type="external"
					default-value="0" />
<set-variable name="tokensThisRequest"
			  value="@(context.Response.StatusCode == 200
				  ? ((long?)((context.Response.Body?.As&lt;JObject&gt;(preserveContent: true))?[&quot;usage&quot;]?[&quot;total_tokens&quot;]) ?? 0L)
				  : 0L)" />
<cache-store-value key="@((string)context.Variables[&quot;tenantQuotaKey&quot;])"
				   value="@(((long)context.Variables[&quot;newQuotaConsumed&quot;]).ToString())"
				   duration="@((int)context.Variables[&quot;quotaTtlSeconds&quot;])"
				   caching-type="external" />
```

That design worked for normal JSON responses, but it conflicted with Server-Sent Events (SSE). Streaming responses are a sequence of `data:` chunks, not one JSON object, so reading `context.Response.Body.As<JObject>()` in outbound either buffers/breaks streaming or cannot observe final streamed usage at the right time.

The native policy removes the custom cache counter from the request path and lets APIM's `llm-token-limit` enforce both TPM and quota. Exact final token accounting for streaming is handled by `ApiManagementGatewayLlmLog`, not by response-body parsing.

## Policy model

- `llm-token-limit` enforces `tokens-per-minute` and `token-quota` per APIM subscription.
- `buffer-response="false"` forwards server-sent event (SSE) chunks immediately.
- `ApiManagementGatewayLlmLog` records the exact token usage after a streamed request completes when `stream_options.include_usage=true`.
- `x-remaining-quota-tokens` is a native APIM estimate. It is useful for diagnostics but is not the pass/fail source for quota enforcement tests.

## Terraform policy template

The template resolves tenant-specific limits first, then applies one native `llm-token-limit` policy instance.

```xml
<!-- STEP 3: Native TPM + quota enforcement -->
<choose>
%{ for sub in tenant_subscriptions ~}
	<!-- ${sub.display_name}: ${sub.tokens_per_minute} TPM | ${sub.token_quota} ${sub.token_quota_period} quota -->
	<when condition="@(context.Subscription.Id == &quot;${sub.subscription_id}&quot;)">
		<set-variable name="tenantQuotaLimit" value="@(${sub.token_quota}L)" />
		<set-variable name="tpmCap"           value="@(${sub.tokens_per_minute})" />
		<set-variable name="quotaPeriodLabel" value="${sub.token_quota_period}" />
	</when>
%{ endfor ~}
	<otherwise>
		<set-variable name="tenantQuotaLimit" value="@(${default_token_quota}L)" />
		<set-variable name="tpmCap"           value="@(${default_tokens_per_minute})" />
		<set-variable name="quotaPeriodLabel" value="${default_token_quota_period}" />
	</otherwise>
</choose>

<llm-token-limit counter-key="@(context.Subscription.Id)"
	tokens-per-minute="@((int)context.Variables[&quot;tpmCap&quot;])"
	token-quota="@((long)context.Variables[&quot;tenantQuotaLimit&quot;])"
	token-quota-period="@((string)context.Variables[&quot;quotaPeriodLabel&quot;])"
	estimate-prompt-tokens="true"
	remaining-tokens-variable-name="remainingTokens"
	remaining-quota-tokens-variable-name="remainingQuotaTokens"
	tokens-consumed-variable-name="tokensConsumed" />
```

The backend section explicitly disables response buffering so streamed chunks are returned to the caller immediately:

```xml
<forward-request buffer-request-body="true" buffer-response="false" />
```

The outbound section only exposes diagnostic headers from variables that the native policy populated. It does not parse or recalculate the response body.

```xml
<set-header name="x-remaining-tpm-tokens" exists-action="override">
	<value>@(context.Variables.ContainsKey("remainingTokens") ? Convert.ToString(context.Variables["remainingTokens"]) : "n/a")</value>
</set-header>
<set-header name="x-remaining-quota-tokens" exists-action="override">
	<value>@(context.Variables.ContainsKey("remainingQuotaTokens") ? Convert.ToString(context.Variables["remainingQuotaTokens"]) : "n/a")</value>
</set-header>
```

## Rendered APIM policy example

The deployed template renders concrete subscription IDs and tenant limits. Subscription IDs are represented below with placeholders so this example can be shared safely:

```xml
<!-- STEP 3: Native TPM + quota enforcement -->
<choose>
	<!-- Adventure Works: 10000 TPM | 3000000 Monthly quota -->
	<when condition="@(context.Subscription.Id == &quot;&lt;adventure-works-subscription-id&gt;&quot;)">
		<set-variable name="tenantQuotaLimit" value="@(3000000L)" />
		<set-variable name="tpmCap" value="@(10000)" />
		<set-variable name="quotaPeriodLabel" value="Monthly" />
	</when>

	<!-- Contoso Corp: 1000 TPM | 500000 Monthly quota -->
	<when condition="@(context.Subscription.Id == &quot;&lt;contoso-subscription-id&gt;&quot;)">
		<set-variable name="tenantQuotaLimit" value="@(500000L)" />
		<set-variable name="tpmCap" value="@(1000)" />
		<set-variable name="quotaPeriodLabel" value="Monthly" />
	</when>

	<!-- Fabrikam Inc: 2000 TPM | 5000 Hourly quota -->
	<when condition="@(context.Subscription.Id == &quot;&lt;fabrikam-subscription-id&gt;&quot;)">
		<set-variable name="tenantQuotaLimit" value="@(5000L)" />
		<set-variable name="tpmCap" value="@(2000)" />
		<set-variable name="quotaPeriodLabel" value="Hourly" />
	</when>

	<!-- Floor Works: 5000 TPM | 1500000 Monthly quota -->
	<when condition="@(context.Subscription.Id == &quot;&lt;floor-works-subscription-id&gt;&quot;)">
		<set-variable name="tenantQuotaLimit" value="@(1500000L)" />
		<set-variable name="tpmCap" value="@(5000)" />
		<set-variable name="quotaPeriodLabel" value="Monthly" />
	</when>

	<otherwise>
		<set-variable name="tenantQuotaLimit" value="@(5000000L)" />
		<set-variable name="tpmCap" value="@(10000)" />
		<set-variable name="quotaPeriodLabel" value="Monthly" />
	</otherwise>
</choose>

<llm-token-limit counter-key="@(context.Subscription.Id)"
	tokens-per-minute="@((int)context.Variables[&quot;tpmCap&quot;])"
	token-quota="@((long)context.Variables[&quot;tenantQuotaLimit&quot;])"
	token-quota-period="@((string)context.Variables[&quot;quotaPeriodLabel&quot;])"
	estimate-prompt-tokens="true"
	remaining-tokens-variable-name="remainingTokens"
	remaining-quota-tokens-variable-name="remainingQuotaTokens"
	tokens-consumed-variable-name="tokensConsumed" />
```

Rendered streaming forwarding and diagnostic headers:

```xml
<forward-request buffer-request-body="true" buffer-response="false" />

<set-header name="x-remaining-tpm-tokens" exists-action="override">
	<value>@(context.Variables.ContainsKey("remainingTokens") ? Convert.ToString(context.Variables["remainingTokens"]) : "n/a")</value>
</set-header>
<set-header name="x-remaining-quota-tokens" exists-action="override">
	<value>@(context.Variables.ContainsKey("remainingQuotaTokens") ? Convert.ToString(context.Variables["remainingQuotaTokens"]) : "n/a")</value>
</set-header>
```

## Test matrix

| Test | Command | Expected proof |
|---|---|---|
| Direct tenant smoke and isolation | `python test_token_limits.py` | Tenant subscriptions can call the gateway and are isolated under load. |
| SSE contract | `python test_streaming_quota_enforcement.py` | SSE chunks, content, `[DONE]`, and final stream usage are returned. |
| Streaming quota persistence | `python test_streaming_quota_enforcement.py --enforce --tenant fabrikam` | Fabrikam reaches a native hourly quota `403` and remains blocked after a TPM window passes. This consumes the hourly Fabrikam allowance. |
| Block stability and isolation | `python test_quota_block_stability.py --probes 4 --interval 25` | A quota-blocked Fabrikam remains blocked over the observation period while Contoso remains available. Run immediately after the enforcement test. |

## Latest clean-deployment test results

After a clean redeployment, the low-impact streaming test passed:

```text
SSE smoke: HTTP 200 | chunks=10 | usage=21 | TPM header=2000 | quota header=5000
PASS: unbuffered SSE and terminal usage are available.
```

The broader test run showed the native policy can exhaust and re-block Fabrikam, but the `x-remaining-quota-tokens` header can move in non-monotonic ways and a strict repeated-block test observed one intermittent HTTP 200 before subsequent probes returned HTTP 403 again. Treat enforcement status (`403` quota, `429` TPM) and `ApiManagementGatewayLlmLog` as the reliable evidence, not the estimated remaining-quota header.

## Interpretation

A quota test passes based on enforcement behavior:

1. The tenant receives HTTP `403` for an exhausted token quota.
2. The tenant remains blocked after waiting longer than a TPM window but before the quota period boundary.
3. Other tenants remain available.

Do not infer a quota reset only because `x-remaining-quota-tokens` increases. APIM documents that remaining quota is an estimate, particularly for concurrent and streaming requests.

## Current topology assumption

The native policy is suitable for this lab's single StandardV2 APIM instance in one East US region. If a future deployment needs one authoritative quota across multiple APIM regions, workspace gateways, self-hosted gateways, or APIM instances, use a centralized quota service with atomic counter operations.
