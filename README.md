# 🛡️ Server-Sentry: Autonomous Server Guardian

An integrated, self-healing, and maintenance suite for Linux servers. Provides **real-time health monitoring**, **automatic container self-healing**, **safe scheduled cleanup routines**, and **instant Telegram alerts** tagged with your unique server identifier.

---

## 📁 Project Structure

```text
server-sentry/
├── setup.sh                   # 1-Click automated installation & update script (Idempotent)
├── docker-compose.yml          # Container stack definition (Autoheal, Uptime Kuma, Beszel Hub & Agent)
├── .env.example               # Documented environment variable template
├── .env                       # Active server configuration (SERVER_NAME, Telegram, ports, BESZEL_KEY)
├── scripts/
│   ├── auto-update.sh         # Automated daily stack updater (prefers official stable releases)
│   ├── notify-telegram.sh     # Telegram notification dispatcher with [SERVER_NAME] header
│   ├── janitor.sh             # Autonomous maintenance & safe cleanup routine (silent at night)
│   ├── audit-healthchecks.sh  # Real-time container healthcheck & protection audit
│   ├── populate-kuma.py       # Dynamic auto-discovery & monitor populator for Uptime Kuma
│   └── kuma-telegram.js       # Custom Uptime Kuma Telegram notification provider
└── README.md                  # This documentation
```

---

## 📋 Environment Variables (`.env`)

All parameters are configured in `.env` and documented in `.env.example`:

| Variable | Default | Required? | Description |
| :--- | :--- | :---: | :--- |
| `SERVER_NAME` | `PROD-SERVER` | **Yes** | Server identifier tag included in every Telegram alert (e.g., `PROD-01`, `OCI-DINO`). |
| `TELEGRAM_BOT_TOKEN` | *(empty)* | **Yes** | Telegram Bot HTTP API token obtained from [@BotFather](https://t.me/BotFather). |
| `TELEGRAM_CHAT_ID` | *(empty)* | **Yes** | Destination Telegram Chat ID, Group ID, or Channel ID. |
| `BESZEL_KEY` | *(empty)* | *Optional* | Public key generated in the Beszel Hub web UI (port 8090) to authenticate `beszel-agent`. |
| `UPTIME_KUMA_PORT` | `3001` | No | Port for the Uptime Kuma web dashboard. |
| `BESZEL_PORT` | `8090` | No | Port for the Beszel Hub hardware dashboard. |
| `ALERT_DISK_THRESHOLD_PERCENT` | `85` | No | Disk usage percentage threshold for critical emergency Telegram alerts. |
| `ALERT_RAM_THRESHOLD_PERCENT` | `90` | No | RAM memory usage percentage threshold for daily health warnings. |
| `PRUNE_UNTIL_HOURS` | `72h` | No | Safe age threshold for deleting untagged Docker images and stopped containers. |
| `AUTOHEAL_INTERVAL` | `20` | No | Interval in seconds between container health checks. |
| `AUTOHEAL_START_PERIOD` | `60` | No | Boot grace period in seconds before Autoheal begins restarting failing containers. |

---

## ⚡ 1-Click Installation & Updates (`setup.sh`)

`setup.sh` is **100% idempotent**: run it on initial setup, or whenever you modify any value in `.env`.

### Quickstart:

1. **Clone or copy the `server-sentry` directory** to your server (e.g., `~/server-sentry` or `/opt/server-sentry`):
   ```bash
   cd /path/to/server-sentry
   ```

2. **Configure `.env`:**
   ```bash
   cp .env.example .env   # if .env does not already exist
   nano .env
   ```
   * Set `SERVER_NAME`, `TELEGRAM_BOT_TOKEN`, and `TELEGRAM_CHAT_ID`.

3. **Run the setup script:**
   ```bash
   ./setup.sh
   ```

### What `setup.sh` does automatically:
* ✅ Validates prerequisites (Docker & Docker Compose).
* ✅ Grants execution permissions across all scripts (`chmod +x`).
* ✅ Hardens Docker log storage (`/etc/docker/daemon.json`) to prevent disk exhaustion.
* ✅ Registers the **nightly 03:00 AM maintenance cronjob** (without duplicates).
* ✅ Deploys or updates the Docker stack (`docker compose up -d`).
* ✅ **Dynamically discovers active apps and proxy domains** and syncs them into Uptime Kuma.
* ✅ Sends an instant verification message to Telegram tagged with `🛡️ [SERVER_NAME]`.
* ✅ Prints dashboard URLs and connection details.

> 💡 **Seamless updates:** Whenever you modify `.env`, just rerun `./setup.sh`. Docker will only reload the affected containers.

---

## 🤖 Telegram Bot Setup & Obtaining `TELEGRAM_CHAT_ID`

1. **Create your Bot:**
   * Open Telegram and message [@BotFather](https://t.me/BotFather).
   * Send `/newbot`, choose a display name and username ending in `_bot`.
   * Copy the HTTP API token (this is your `TELEGRAM_BOT_TOKEN`).
2. **Send Initial Message:**
   * Search for your new bot in Telegram and click **Start** (or send `/start`).
   * *(If receiving alerts in a group, add the bot as a member to the group and send a message there).*
3. **Retrieve Chat ID:**
   * Run this command on your server (replace with your actual token):
     ```bash
     curl -s "https://api.telegram.org/bot<YOUR_TOKEN_HERE>/getUpdates"
     ```
   * Look for the `"chat": { "id": 123456789 }` field in the JSON response.
   * That number is your `TELEGRAM_CHAT_ID` (negative numbers indicate groups, e.g., `-100...`).
4. **Paste into `.env` and run `./setup.sh`.**

---

## 📊 Activating Hardware Metrics (`Beszel Agent`)

The `beszel-agent` remains paused until you configure its public key to ensure secure, authenticated telemetry collection.

1. Access the Beszel Hub web interface:
   `http://<SERVER_IP>:8090` (or via your configured domain/reverse proxy).
2. Create your initial admin account.
3. Click the **"Add System"** button:
   * **Name:** Your server name (e.g., `PROD-SERVER`).
   * **Host / IP:** Enter your host's internal IP (e.g., `10.0.1.251` or `172.17.0.1`). *Do not use `127.0.0.1` as it points to the container namespace.* Port: `45876`.
   * The dashboard will generate an SSH public key (starts with `ssh-ed25519 ...`). Copy it.
4. Open `.env` and paste it inside double quotes:
   ```dotenv
   BESZEL_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5..."
   ```
   > ⚠️ **Important:** Always enclose the key in **double quotes** (`"..."`) because public keys contain a space separating the key type from the base64 string.
5. Rerun the setup:
   ```bash
   ./setup.sh
   ```
6. `server-sentry-beszel-agent` will start immediately and stream real-time CPU, RAM, disk I/O, and per-container Docker stats to the dashboard.

---

## 🌐 Dynamic Service Discovery in Uptime Kuma

When `./setup.sh` runs, [`scripts/populate-kuma.py`](file:///home/ubuntu/projects/server-sentry/scripts/populate-kuma.py) automatically:
* Detects proxy domains from **Nginx Proxy Manager** (`/data/nginx/proxy_host/*.conf`).
* Detects running Docker containers exposing web ports.
* Registers new monitors in Uptime Kuma and binds them to the default Telegram alert channel.
* Idempotent: Never duplicates or overwrites existing monitors.

To run service discovery manually at any time:
```bash
sudo ./scripts/populate-kuma.py
```

---

## 🧹 Autonomous Cleanup Routine (`Janitor`)

[`scripts/janitor.sh`](file:///home/ubuntu/projects/server-sentry/scripts/janitor.sh) runs automatically every night at 03:00 AM and can also be triggered manually:
```bash
./scripts/janitor.sh
```

**Safety Guarantees:**
* Prunes stopped containers, dangling images, and build cache older than 72h.
* **NEVER** prunes persistent data volumes (protects MongoDB, PostgreSQL, Redis, etc.).
* Vacuums archived systemd logs (`journalctl`) retaining the last 7 days / 200MB.
* **Nighttime Silent Delivery:** Regular successful reports are sent with `disable_notification=true` (silent delivery without phone vibration or ringtone).
* **Emergency Alert Mode:** If disk usage exceeds the threshold or an unhealthy container is detected, alerts switch to audible notifications.

---

## 🔄 Autonomous Daily Stack Updates (`auto-update.sh`)

[`scripts/auto-update.sh`](file:///home/ubuntu/projects/server-sentry/scripts/auto-update.sh) continuously tracks official **stable** releases for all Server-Sentry components (`louislam/uptime-kuma:2`, `henrygd/beszel:latest`, `henrygd/beszel-agent:latest`, `willfarrell/autoheal:latest`).

It runs automatically as **Step 0** of the nightly maintenance cycle (03:00 AM) and can also be triggered manually at any time:
```bash
./scripts/auto-update.sh
```

**Update Lifecycle:**
1. **Digest Comparison:** Checks remote registries without recreating containers if no changes exist.
2. **Automated Safety Backup:** Creates a pre-update snapshot of the Uptime Kuma SQLite database before restarting containers.
3. **Seamless Recreation:** Restarts only the containers that have new stable digests (`docker compose up -d --remove-orphans`).
4. **Monitor Re-synchronization:** Automatically triggers `populate-kuma.py` to ensure all monitors and notification hooks are intact.
5. **Silent Notification:** Sends a silent notification via Telegram with the list of upgraded components.
6. **Automatic Garbage Collection:** Outdated image layers are pruned by Janitor right after the update.

---

## 🔄 Self-Healing Healthcheck Audit

Inspect which containers on the server are currently safeguarded by Autoheal:
```bash
./scripts/audit-healthchecks.sh
```

Containers reporting `🟢 Protected` will automatically be restarted if their healthcheck fails. Containers with `⚪ No Healthcheck` can be protected simply by adding a `healthcheck:` stanza to their respective `docker-compose.yml`.

---

## 🔒 Recommended Hardening: Docker Log Capping

To prevent container logs from consuming disk space, global rotation is configured via `/etc/docker/daemon.json`:
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  }
}
```
*(Applied automatically by `./setup.sh` if sudo privileges are available).*
