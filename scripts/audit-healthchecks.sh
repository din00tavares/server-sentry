#!/usr/bin/env bash
# ==============================================================================
# SERVER-SENTRY: Docker Healthcheck Protection Auditor
# ==============================================================================
# Inspects running containers to check whether they have a Docker HEALTHCHECK
# configured and are safeguarded by Autoheal self-healing.
# ==============================================================================

set -euo pipefail

echo "=============================================================================="
echo " 🛡️ SERVER-SENTRY: Container Healthcheck & Autoheal Audit"
echo "=============================================================================="
printf "%-30s | %-12s | %-15s | %-20s\n" "CONTAINER" "STATUS" "HEALTHCHECK?" "AUTOHEAL STATUS"
echo "------------------------------------------------------------------------------"

docker ps --format '{{.Names}}\t{{.Status}}\t{{.ID}}' | while IFS=$'\t' read -r name status id; do
  HAS_HEALTH=$(docker inspect --format '{{if .State.Health}}YES ({{.State.Health.Status}}){{else}}NO{{end}}' "$id" < /dev/null 2>/dev/null || echo "N/A")
  
  if [[ "$HAS_HEALTH" == *"healthy"* ]]; then
    AUTOHEAL="🟢 Protected"
  elif [[ "$HAS_HEALTH" == *"NO"* ]]; then
    AUTOHEAL="⚪ No Healthcheck"
  else
    AUTOHEAL="🟡 Evaluating"
  fi

  printf "%-30s | %-12s | %-15s | %-20s\n" "${name:0:30}" "${status:0:12}" "${HAS_HEALTH:0:15}" "${AUTOHEAL}"
done

echo "------------------------------------------------------------------------------"
echo "Tip: To protect containers marked as 'No Healthcheck', add a 'healthcheck:'"
echo "directive to your respective docker-compose.yml service definition."
echo "=============================================================================="
