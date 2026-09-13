#!/usr/bin/env bash
# ==============================================================================
# SERVER-SENTRY: Telegram Notification Dispatcher
# ==============================================================================
# Sends messages tagged with [SERVER_NAME] configured in .env.
# Usage:
#   ./notify-telegram.sh "Your message here"
#   ./notify-telegram.sh --silent "Silent notification"
#   echo "Piped message" | ./notify-telegram.sh
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load configuration from .env if available
if [[ -f "${PROJECT_DIR}/.env" ]]; then
  # shellcheck disable=SC1091
  set -a
  source "${PROJECT_DIR}/.env"
  set +a
fi

SERVER_NAME="${SERVER_NAME:-PROD-SERVER}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

SILENT="false"
# Check if the first argument specifies silent delivery
if [[ "${1:-}" == "--silent" || "${1:-}" == "-s" ]]; then
  SILENT="true"
  shift
fi

# Retrieve message from argument or stdin
if [[ $# -gt 0 ]]; then
  RAW_MSG="$*"
else
  RAW_MSG="$(cat -)"
fi

if [[ -z "${RAW_MSG}" ]]; then
  echo "[notify-telegram] Warning: Empty message received. No notification sent."
  exit 0
fi

FORMATTED_MSG="🛡️ <b>[${SERVER_NAME}]</b>
${RAW_MSG}"

# If Telegram is not configured, print to stdout for debugging
if [[ -z "${TELEGRAM_BOT_TOKEN}" || -z "${TELEGRAM_CHAT_ID}" ]]; then
  echo "---------------------------------------------------------"
  echo "[TELEGRAM NOT CONFIGURED] Message that would be sent (silent=${SILENT}):"
  echo -e "${FORMATTED_MSG}"
  echo "---------------------------------------------------------"
  exit 0
fi

# Dispatch via Telegram Bot API
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  -d parse_mode="HTML" \
  -d disable_notification="${SILENT}" \
  --data-urlencode "text=${FORMATTED_MSG}")

HTTP_STATUS=$(echo "${RESPONSE}" | tail -n1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [[ "${HTTP_STATUS}" -ne 200 ]]; then
  echo "[notify-telegram] Error sending message to Telegram (HTTP ${HTTP_STATUS}): ${BODY}" >&2
  exit 1
else
  echo "[notify-telegram] Message sent successfully to [${SERVER_NAME}]."
fi
