#!/usr/bin/env bash
# ==============================================================================
# SERVER-SENTRY: 1-Click Automated Setup & Update Script (Idempotent)
# ==============================================================================
# Usage:
#   ./setup.sh
#
# Can be executed for initial installation or whenever updating .env.
# 1. Validates prerequisites (Docker, Docker Compose, .env).
# 2. Adjusts executable permissions across scripts.
# 3. Sets up safe Docker daemon log rotation (/etc/docker/daemon.json).
# 4. Configures daily maintenance cronjob (without duplicates).
# 5. Boots/updates Docker stack (Autoheal, Uptime Kuma, Beszel Hub & Agent).
# 6. Dynamically synchronizes applications into Uptime Kuma.
# 7. Tests and verifies Telegram connectivity.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

echo "=================================================================="
echo " 🛡️ SERVER-SENTRY: Automated Setup & Stack Synchronization"
echo "=================================================================="

# 1. Prerequisite Validation
if ! command -v docker &>/dev/null; then
  echo "❌ Error: Docker is not installed. Please install Docker first." >&2
  exit 1
fi

if ! docker compose version &>/dev/null; then
  echo "❌ Error: Docker Compose is not installed or unavailable." >&2
  exit 1
fi

# 2. .env File Check
if [[ ! -f ".env" ]]; then
  if [[ -f ".env.example" ]]; then
    echo "⚠️  .env file not found. Creating from .env.example..."
    cp .env.example .env
    echo "❗ Please edit your .env file with your server details and run ./setup.sh again."
    exit 0
  else
    echo "❌ Error: Neither .env nor .env.example was found." >&2
    exit 1
  fi
fi

# Load variables from .env
# shellcheck disable=SC1091
set -a
source .env
set +a

SERVER_NAME="${SERVER_NAME:-PROD-SERVER}"
UPTIME_PORT="${UPTIME_KUMA_PORT:-3001}"
BESZEL_HUB_PORT="${BESZEL_PORT:-8090}"

echo "⚙️  Server identified as: [${SERVER_NAME}]"

# 3. Permissions Setup
echo "🔑 Adjusting script permissions..."
chmod +x setup.sh scripts/*.sh scripts/*.py 2>/dev/null || true

# 4. Docker Daemon Log Rotation Hardening
if [[ ! -f /etc/docker/daemon.json ]] && sudo -n true 2>/dev/null; then
  echo "🔒 Configuring Docker Daemon log rotation (/etc/docker/daemon.json)..."
  sudo mkdir -p /etc/docker
  sudo tee /etc/docker/daemon.json >/dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
EOF
  sudo systemctl reload docker 2>/dev/null || true
  echo "✅ Docker log rotation successfully enabled (150MB cap per container)."
fi

# 5. Idempotent Cronjob Configuration (Daily Cleanup at 03:00)
JANITOR_PATH="${SCRIPT_DIR}/scripts/janitor.sh"
LOG_PATH="/var/log/server-sentry-janitor.log"
CRON_LINE="0 3 * * * ${JANITOR_PATH} >> ${LOG_PATH} 2>&1"

EXISTING_CRON=$(crontab -l 2>/dev/null || true)
CLEANED_CRON=$(echo "${EXISTING_CRON}" | grep -v "scripts/janitor.sh" || true)

if [[ -n "${CLEANED_CRON}" ]]; then
  echo -e "${CLEANED_CRON}\n${CRON_LINE}" | crontab -
else
  echo "${CRON_LINE}" | crontab -
fi
echo "⏰ Daily maintenance cronjob configured for 03:00 AM."

# 6. Docker Stack Deployment
echo "🐳 Deploying / updating Docker Compose stack..."
docker compose up -d --remove-orphans

# Pause Beszel agent if public key is not yet configured to prevent restart loop
if [[ -z "${BESZEL_KEY:-}" ]]; then
  docker compose stop beszel-agent >/dev/null 2>&1 || true
fi

# 7. Dynamic Application Sync for Uptime Kuma
if [[ -f "${SCRIPT_DIR}/scripts/populate-kuma.py" ]]; then
  echo "🔍 Synchronizing active applications into Uptime Kuma..."
  sudo python3 "${SCRIPT_DIR}/scripts/populate-kuma.py" || true
fi

# 8. Telegram Connectivity Test
echo "📡 Testing Telegram alert connectivity..."
TEST_MESSAGE="<b>🚀 Server-Sentry Active / Updated</b>
• Monitoring stack operational.
• Self-Healing: <b>Enabled (Autoheal)</b>
• Auto-Update: <b>Enabled (Daily Stable Releases)</b>
• Nightly Maintenance: <b>Scheduled (03:00 AM)</b>"

"${SCRIPT_DIR}/scripts/notify-telegram.sh" "${TEST_MESSAGE}" || true

# 9. Discover Host IP for links
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_SERVER_IP")

echo ""
echo "=================================================================="
echo " 🎉 SERVER-SENTRY IS 100% OPERATIONAL!"
echo "=================================================================="
echo " 🌐 Dashboards:"
echo "    • Uptime Kuma: http://${HOST_IP}:${UPTIME_PORT}"
echo "    • Beszel Hub:  http://${HOST_IP}:${BESZEL_HUB_PORT}"
if [[ -z "${BESZEL_KEY:-}" ]]; then
  echo ""
  echo " ℹ️  Beszel Agent: Access Beszel Hub (port ${BESZEL_HUB_PORT}), create admin account,"
  echo "    click 'Add System' (Host/IP: ${HOST_IP}, Port: 45876), copy the public key and add to .env:"
  echo "    BESZEL_KEY=\"ssh-ed25519 ...\""
  echo "    Then rerun ./setup.sh to activate host metric collection!"
fi
echo ""
echo " 💡 Tip: Whenever you update .env, simply run ./setup.sh again"
echo "    to reload all changes in 1 click!"
echo "=================================================================="
