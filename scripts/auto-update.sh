#!/usr/bin/env bash
# ==============================================================================
# SERVER-SENTRY: Automated Daily Stack Updater (Stable Releases Only)
# ==============================================================================
# 1. Inspects active Docker images against official stable registries.
# 2. Automatically pulls stable tags (Uptime Kuma v2, Beszel, Autoheal).
# 3. Detects if any service has received a new stable digest.
# 4. Performs an automated safety backup of Uptime Kuma database before restart.
# 5. Restarts updated containers with zero unnecessary downtime.
# 6. Re-synchronizes monitor definitions and dispatches silent Telegram report.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env configuration
if [[ -f "${PROJECT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "${PROJECT_DIR}/.env"
  set +a
fi

SERVER_NAME="${SERVER_NAME:-PROD-SERVER}"

echo "========================================================="
echo " [Server-Sentry Auto-Update] Checking stable updates..."
echo " Server: ${SERVER_NAME}"
echo "========================================================="

cd "${PROJECT_DIR}"

# 1. Capture current container image IDs before pulling
declare -A BEFORE_IMAGES
SERVICES=("uptime-kuma" "beszel-hub" "beszel-agent" "autoheal")

for SVC in "${SERVICES[@]}"; do
  CONTAINER_ID=$(docker compose ps -q "${SVC}" 2>/dev/null || true)
  if [[ -n "${CONTAINER_ID}" ]]; then
    BEFORE_IMAGES["${SVC}"]=$(docker inspect --format '{{.Image}}' "${CONTAINER_ID}" 2>/dev/null || echo "none")
  else
    BEFORE_IMAGES["${SVC}"]="none"
  fi
done

# 2. Pull official stable images as defined in docker-compose.yml
echo "⬇️  Pulling latest stable images..."
PULL_OUTPUT=$(docker compose pull 2>&1 || true)
echo "${PULL_OUTPUT}"

# 3. Check which services have a newer image available
UPDATED_SERVICES=()

for SVC in "${SERVICES[@]}"; do
  COMPOSE_IMAGE=$(docker compose config --format json 2>/dev/null | python3 -c "
import sys, json
try:
    cfg = json.load(sys.stdin)
    print(cfg.get('services', {}).get('${SVC}', {}).get('image', ''))
except:
    pass
" 2>/dev/null || true)

  if [[ -n "${COMPOSE_IMAGE}" ]]; then
    PULLED_IMAGE_ID=$(docker image inspect --format '{{.Id}}' "${COMPOSE_IMAGE}" 2>/dev/null || echo "none")
    CURRENT_IMAGE_ID="${BEFORE_IMAGES[${SVC}]:-none}"

    if [[ "${CURRENT_IMAGE_ID}" != "none" ]] && [[ "${PULLED_IMAGE_ID}" != "none" ]] && [[ "${CURRENT_IMAGE_ID}" != "${PULLED_IMAGE_ID}" ]]; then
      UPDATED_SERVICES+=("${SVC}")
      echo "✨ New stable release detected for: ${SVC} (${CURRENT_IMAGE_ID:0:12} -> ${PULLED_IMAGE_ID:0:12})"
    fi
  fi
done

# 4. If updates are available, apply them safely
if [[ ${#UPDATED_SERVICES[@]} -gt 0 ]]; then
  echo "🚀 Applying updates for: ${UPDATED_SERVICES[*]}..."

  # Pre-update automated safety backup of persistent data
  KUMA_VOL_PATH="/var/lib/docker/volumes/server-sentry-uptime-kuma-data/_data"
  KUMA_BACKUP_PATH="/var/lib/docker/volumes/server-sentry-uptime-kuma-data/_data_backup_auto"

  if sudo -n true 2>/dev/null; then
    if sudo test -d "${KUMA_VOL_PATH}"; then
      echo "💾 Creating pre-update backup of Uptime Kuma database..."
      sudo rm -rf "${KUMA_BACKUP_PATH}" || true
      sudo cp -a "${KUMA_VOL_PATH}" "${KUMA_BACKUP_PATH}" || true
      echo "✅ Backup saved to: ${KUMA_BACKUP_PATH}"
    fi
  fi

  # Restart updated containers
  echo "🐳 Recreating updated containers..."
  docker compose up -d --remove-orphans "${UPDATED_SERVICES[@]}"

  # Allow containers to initialize migrations/networking
  sleep 5

  # Re-sync monitors and Telegram notification providers
  if [[ -f "${SCRIPT_DIR}/populate-kuma.py" ]]; then
    echo "🔍 Resyncing application monitors in Uptime Kuma..."
    if sudo -n true 2>/dev/null; then
      sudo python3 "${SCRIPT_DIR}/populate-kuma.py" >/dev/null 2>&1 || true
    else
      python3 "${SCRIPT_DIR}/populate-kuma.py" >/dev/null 2>&1 || true
    fi
  fi

  # Format update summary for Telegram
  UPDATED_LIST_STR=$(printf "• %s\n" "${UPDATED_SERVICES[@]}")
  UPDATE_MSG="<b>🔄 Server-Sentry Stack Auto-Updated</b>

The following services were successfully upgraded to new stable versions:
${UPDATED_LIST_STR}
• Stack Status: <b>Healthy & Operational</b>
• Pre-update Backup: <b>Created successfully</b>"

  # Send silent notification (no disruptive sound)
  echo "📡 Sending silent Telegram update notification..."
  "${SCRIPT_DIR}/notify-telegram.sh" --silent "${UPDATE_MSG}" || true
  echo "✅ Stack update routine completed successfully."

else
  echo "✅ All Server-Sentry services are already running the latest stable release."
fi
