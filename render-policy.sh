#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# render-policy.sh — Render policy.xml.tftpl → policy.xml using
#                     live Terraform state values (for learning/review)
#
# Usage:  ./render-policy.sh          # renders to policy.xml
#         ./render-policy.sh -o out   # renders to a custom file
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

OUTPUT="policy.xml"
while getopts "o:" opt; do
  case $opt in
    o) OUTPUT="$OPTARG" ;;
    *) echo "Usage: $0 [-o output_file]"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Ensure Terraform is initialized
if [ ! -d .terraform ]; then
  echo "ERROR: Run 'terraform init' first." >&2
  exit 1
fi

echo "Rendering policy.xml.tftpl → $OUTPUT ..."

# Use terraform console to evaluate the templatefile() with live state values.
# This gives us the exact same XML that Terraform would deploy to APIM.
EXPR='templatefile("${path.module}/policy.xml.tftpl", { backend_id = azapi_resource.apim-backend-pool-openai.name, content_safety_backend_id = azurerm_api_management_backend.content_safety_backend.name, tenant_subscriptions = local.tenant_subscriptions, default_tokens_per_minute = var.default_tokens_per_minute, default_token_quota = var.default_token_quota, default_token_quota_period = var.default_token_quota_period })'

rendered=$(echo "$EXPR" | terraform console -no-color 2>&1)

if [ $? -ne 0 ]; then
  echo "ERROR: terraform console failed:" >&2
  echo "$rendered" >&2
  exit 1
fi

# terraform console wraps multi-line strings in <<-EOT...EOT
# Strip the markers and write the XML content
echo "$rendered" | sed '1{/^<<-\?EOT$/d}' | sed '${/^EOT$/d}' > "$OUTPUT"

echo "Done! Rendered $(wc -l < "$OUTPUT") lines → $OUTPUT"
echo ""
echo "Tip: Compare with the template:"
echo "  diff --color policy.xml.tftpl $OUTPUT"
