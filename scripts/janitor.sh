#!/usr/bin/env bash
# ==============================================================================
# SERVER-SENTRY: Autonomous Maintenance & Safe Cleaner (Janitor)
# ==============================================================================
# 1. Runs safe Docker pruning (never touches persistent database volumes).
# 2. Vacuums systemd journal logs to prevent disk saturation.
# 3. Measures freed disk space and container health metrics.
# 4. Dispatches a formatted report with [SERVER_NAME] to Telegram (silent at night).
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

PRUNE_UNTIL="${PRUNE_UNTIL_HOURS:-72h}"
DISK_ALERT_THRESHOLD="${ALERT_DISK_THRESHOLD_PERCENT:-85}"
RAM_ALERT_THRESHOLD="${ALERT_RAM_THRESHOLD_PERCENT:-90}"

echo "========================================================="
echo " [Server-Sentry Janitor] Starting maintenance routine..."
echo "========================================================="

# 0. Check and apply stable updates for Server-Sentry stack
if [[ -f "${SCRIPT_DIR}/auto-update.sh" ]]; then
  echo "[0/4] Checking and applying stable stack updates..."
  "${SCRIPT_DIR}/auto-update.sh" || true
fi

# 1. Pre-cleanup metrics
DISK_BEFORE_KB=$(df -k / | awk 'NR==2 {print $3}')
DISK_TOTAL_KB=$(df -k / | awk 'NR==2 {print $2}')

# 2. Safe Docker cleanup (stopped containers, dangling/unused images >72h, build cache)
# SAFETY NOTE: We DO NOT prune volumes (docker volume prune) to safeguard persistent DBs.
echo "[1/3] Removing stopped containers older than ${PRUNE_UNTIL}..."
docker container prune -f --filter "until=${PRUNE_UNTIL}" < /dev/null || true

echo "[2/3] Removing unused untagged images older than ${PRUNE_UNTIL}..."
docker image prune -af --filter "until=${PRUNE_UNTIL}" < /dev/null || true

echo "[3/3] Removing outdated Docker build cache..."
docker builder prune -af --filter "until=${PRUNE_UNTIL}" < /dev/null || true

# 3. Compact system journal logs if journalctl exists
if command -v journalctl &>/dev/null; then
  echo "[System] Vacuuming journalctl logs (retaining last 7 days / 200MB)..."
  if sudo -n true 2>/dev/null; then
    sudo journalctl --no-pager --vacuum-time=7d --vacuum-size=200M >/dev/null 2>&1 || true
  else
    journalctl --no-pager --vacuum-time=7d --vacuum-size=200M >/dev/null 2>&1 || true
  fi
fi

# 4. Post-cleanup metrics
DISK_AFTER_KB=$(df -k / | awk 'NR==2 {print $3}')
DISK_PERCENT=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
DISK_AVAIL_HUMAN=$(df -h / | awk 'NR==2 {print $4}')
DISK_TOTAL_HUMAN=$(df -h / | awk 'NR==2 {print $2}')

# Calculate reclaimed space
if [[ ${DISK_BEFORE_KB} -ge ${DISK_AFTER_KB} ]]; then
  FREED_KB=$((DISK_BEFORE_KB - DISK_AFTER_KB))
  if [[ ${FREED_KB} -ge 1048576 ]]; then
    FREED_HUMAN="$(awk "BEGIN {printf \"%.2f GB\", ${FREED_KB}/1048576}")"
  elif [[ ${FREED_KB} -ge 1024 ]]; then
    FREED_HUMAN="$(awk "BEGIN {printf \"%.1f MB\", ${FREED_KB}/1024}")"
  else
    FREED_HUMAN="${FREED_KB} KB"
  fi
else
  FREED_HUMAN="0 MB (data stable)"
fi

# 5. Container diagnosis
TOTAL_CONTAINERS=$(docker ps -q | wc -l | tr -d ' ')
HEALTHY_CONTAINERS=$(docker ps --filter "health=healthy" -q | wc -l | tr -d ' ')
UNHEALTHY_CONTAINERS=$(docker ps --filter "health=unhealthy" -q | wc -l | tr -d ' ')

# 6. Current RAM usage
RAM_USED_PERCENT=$(free | awk '/Mem:/ {printf "%.0f", $3/$2 * 100}')

# 7. Construct report message
STATUS_EMOJI="✅"
if [[ "${DISK_PERCENT}" -ge "${DISK_ALERT_THRESHOLD}" ]] || [[ "${UNHEALTHY_CONTAINERS}" -gt 0 ]]; then
  STATUS_EMOJI="⚠️"
fi

REPORT_MSG="<b>${STATUS_EMOJI} Daily Maintenance & Health Report</b>

🧹 <b>Cleanup Completed:</b>
• Reclaimed disk space: <b>${FREED_HUMAN}</b>
• Retention applied: images and cache > ${PRUNE_UNTIL}

📊 <b>Resource Status:</b>
• Disk: <b>${DISK_PERCENT}% used</b> (${DISK_AVAIL_HUMAN} free of ${DISK_TOTAL_HUMAN})
• RAM Memory: <b>${RAM_USED_PERCENT}% in use</b>

⚙️ <b>Docker Containers:</b>
• Total Active: <b>${TOTAL_CONTAINERS}</b>
• Healthy Containers: <b>${HEALTHY_CONTAINERS}</b>"

if [[ "${UNHEALTHY_CONTAINERS}" -gt 0 ]]; then
  REPORT_MSG="${REPORT_MSG}
• ⚠️ <b>Warning:</b> ${UNHEALTHY_CONTAINERS} container(s) reported UNHEALTHY status!"
fi

if [[ "${DISK_PERCENT}" -ge "${DISK_ALERT_THRESHOLD}" ]]; then
  REPORT_MSG="${REPORT_MSG}

🚨 <b>DISK USAGE ALERT:</b> Disk usage reached <b>${DISK_PERCENT}%</b> (threshold: ${DISK_ALERT_THRESHOLD}%)!"
fi

# 8. Dispatch notification
echo "========================================================="
echo "Report generated successfully:"
echo "${REPORT_MSG}"
echo "========================================================="

# Sends in SILENT mode (no audio, no vibration) for normal nightly maintenance.
# Triggers an audible alert only if an emergency threshold or unhealthy container is detected.
if [[ "${STATUS_EMOJI}" == "✅" ]]; then
  echo "[Server-Sentry] Sending report in SILENT mode (no audio/vibration)..."
  "${SCRIPT_DIR}/notify-telegram.sh" --silent "${REPORT_MSG}"
else
  echo "[Server-Sentry] ⚠️ Critical alert detected! Sending with standard notification sound..."
  "${SCRIPT_DIR}/notify-telegram.sh" "${REPORT_MSG}"
fi
