#!/usr/bin/env bash
# ==============================================================================
# SERVER-SENTRY: Autonomous Project & Service Discovery Routine
# ==============================================================================
# 1. Scans Nginx Proxy Manager for newly published domains & web apps.
# 2. Scans Docker daemon for newly spawned containers, bots, and workers.
# 3. Synchronizes new monitors into Uptime Kuma with Telegram alerts enabled.
# 4. Traps errors and dispatches emergency alert to Telegram if discovery fails.
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

# Error handler: Dispatches an emergency alert to Telegram if any unhandled error occurs
handle_error() {
  local exit_code="$?"
  local line_number="$1"
  local last_command="${BASH_COMMAND}"

  echo "=========================================================" >&2
  echo " [Server-Sentry Discovery] FATAL ERROR on line ${line_number} (exit code ${exit_code})" >&2
  echo " Failed command: ${last_command}" >&2
  echo "=========================================================" >&2

  local error_msg="🚨 <b>Project Discovery Routine FAILED!</b>

• Status: <b>Discovery aborted due to an error</b>
• Failed at line: <b>${line_number}</b>
• Exit code: <b>${exit_code}</b>
• Command: <code>${last_command}</code>

⚠️ Could not scan or register new projects into monitoring.
Check log: <code>${PROJECT_DIR}/logs/sync-monitors.log</code>"

  if [[ -f "${SCRIPT_DIR}/notify-telegram.sh" ]]; then
    "${SCRIPT_DIR}/notify-telegram.sh" "${error_msg}" || true
  fi

  exit "${exit_code}"
}

trap 'handle_error ${LINENO}' ERR

echo "========================================================="
echo " [Server-Sentry] Starting project discovery & monitor sync..."
echo " Time: $(date)"
echo "========================================================="

# Execute discovery script (sudo required for direct access to Uptime Kuma sqlite volume)
if sudo -n true 2>/dev/null; then
  sudo python3 "${SCRIPT_DIR}/populate-kuma.py"
else
  python3 "${SCRIPT_DIR}/populate-kuma.py"
fi

echo "========================================================="
echo " [Server-Sentry] Project discovery finished successfully."
echo "========================================================="
