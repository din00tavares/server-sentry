#!/usr/bin/env python3
# ==============================================================================
# SERVER-SENTRY: Dynamic Uptime Kuma Populator & Synchronizer
# ==============================================================================
# 100% Generic and Autonomous:
# 1. Dynamically discovers proxy domains configured in Nginx Proxy Manager.
# 2. Dynamically discovers active Docker containers exposing web ports.
# 3. Discovers Server-Sentry internal services (Beszel Hub, Uptime Kuma).
# 4. Configures/syncs default Telegram notification provider using .env values.
# 5. Idempotent: Preserves existing monitors and only inserts newly detected apps.
# ==============================================================================

import os
import re
import sys
import json
import sqlite3
import subprocess

def load_env(env_path):
    env = {}
    if os.path.exists(env_path):
        with open(env_path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    k, v = line.split('=', 1)
                    env[k.strip()] = v.strip().strip('"').strip("'")
    return env

def get_npm_domains():
    """Dynamically discovers proxy domains configured in Nginx Proxy Manager."""
    discovered = []
    try:
        res = subprocess.run(
            ['docker', 'ps', '--format', '{{.Names}}\t{{.Image}}'],
            capture_output=True, text=True, check=True
        )
        npm_containers = [
            line.split('\t')[0] for line in res.stdout.strip().split('\n')
            if 'nginx-proxy-manager' in line.lower()
        ]
        
        if not npm_containers:
            return discovered

        npm_name = npm_containers[0]
        list_files_cmd = "ls /data/nginx/proxy_host/*.conf 2>/dev/null || true"
        files_out = subprocess.run(['docker', 'exec', npm_name, 'sh', '-c', list_files_cmd], capture_output=True, text=True)
        conf_files = files_out.stdout.strip().split()

        for conf_file in conf_files:
            cat_cmd = f"cat {conf_file}"
            c = subprocess.run(['docker', 'exec', npm_name, 'sh', '-c', cat_cmd], capture_output=True, text=True)
            content = c.stdout

            # Extract server_name domains
            names = []
            m_names = re.findall(r'server_name\s+([^;]+);', content)
            for m in m_names:
                for domain in m.split():
                    domain = domain.strip()
                    if '.' in domain and not domain.startswith('_'):
                        names.append(domain)

            if not names:
                continue

            has_ssl = 'ssl_certificate' in content or 'listen 443' in content
            scheme = 'https' if has_ssl else 'http'

            for domain in names:
                sub = domain.split('.')[0].replace('-', ' ').title()
                discovered.append({
                    "name": sub,
                    "url": f"{scheme}://{domain}",
                    "accepted_codes": '["200-299","300-399","404"]' if 'api' in domain else '["200-299","300-399"]',
                    "description": f"Automatically discovered via Nginx Proxy Manager ({domain})"
                })
    except Exception as e:
        print(f"ℹ️  No domains extracted from NPM: {e}")

    return discovered

def get_docker_http_services():
    """Discovers Docker containers with published web ports on the host."""
    discovered = []
    try:
        res = subprocess.run(
            ['docker', 'ps', '--format', '{{.Names}}\t{{.Ports}}'],
            capture_output=True, text=True, check=True
        )
        for line in res.stdout.strip().split('\n'):
            if not line.strip():
                continue
            parts = line.split('\t')
            name = parts[0]
            ports_raw = parts[1] if len(parts) > 1 else ""

            # Exclude internal sentry and proxy manager containers to avoid duplicates
            if 'server-sentry' in name or 'nginx-proxy-manager' in name:
                continue

            matches = re.findall(r'(?:0\.0\.0\.0|127\.0\.0\.1):(\d+)->(\d+)/tcp', ports_raw)
            for host_port, cont_port in matches:
                p = int(host_port)
                if p in [80, 443, 22, 25, 465, 587, 993, 4190, 27017, 6379]:
                    continue
                
                friendly_name = name.replace('-', ' ').replace('_', ' ').title()
                discovered.append({
                    "name": f"{friendly_name} (Port {host_port})",
                    "url": f"http://127.0.0.1:{host_port}",
                    "accepted_codes": '["200-299","300-399","401","404"]',
                    "description": f"Docker container service detected on host port {host_port}"
                })
    except Exception as e:
        print(f"ℹ️  Warning while scanning Docker ports: {e}")

    return discovered

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_dir = os.path.abspath(os.path.join(script_dir, '..'))
    env_file = os.path.join(project_dir, '.env')
    env = load_env(env_file)

    server_name = env.get('SERVER_NAME', 'PROD-SERVER')
    bot_token = env.get('TELEGRAM_BOT_TOKEN', '')
    chat_id = env.get('TELEGRAM_CHAT_ID', '')
    kuma_port = env.get('UPTIME_KUMA_PORT', '3001')
    beszel_port = env.get('BESZEL_PORT', '8090')

    db_path = '/var/lib/docker/volumes/server-sentry-uptime-kuma-data/_data/kuma.db'
    if not os.path.exists(db_path):
        print(f"Error: Uptime Kuma database not found at {db_path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    cur = conn.cursor()

    # 1. Configure or update default Telegram notification provider from .env
    notif_id = None
    if bot_token and chat_id:
        config_json = json.dumps({
            "type": "telegram",
            "name": f"Telegram [{server_name}]",
            "telegramBotToken": bot_token,
            "telegramChatID": chat_id,
            "telegramSendSilently": False,
            "telegramProtectContent": False
        })

        cur.execute("SELECT id FROM notification WHERE user_id = 1 LIMIT 1")
        row = cur.fetchone()
        if row:
            notif_id = row[0]
            cur.execute(
                "UPDATE notification SET name = ?, config = ?, is_default = 1 WHERE id = ?",
                (f"Telegram [{server_name}]", config_json, notif_id)
            )
            print(f"🔔 Telegram notification provider synchronized: Telegram [{server_name}] (ID: {notif_id})")
        else:
            cur.execute(
                "INSERT INTO notification (name, active, user_id, is_default, config) VALUES (?, 1, 1, 1, ?)",
                (f"Telegram [{server_name}]", config_json)
            )
            notif_id = cur.lastrowid
            print(f"🔔 New Telegram notification provider created: Telegram [{server_name}] (ID: {notif_id})")

    # 2. Dynamic Discovery
    print("\n🔍 Initiating dynamic service discovery...")
    candidates = []

    # A. Domains from Nginx Proxy Manager
    npm_apps = get_npm_domains()
    print(f"  • {len(npm_apps)} domain(s) discovered in Nginx Proxy Manager.")
    candidates.extend(npm_apps)

    # B. If no external NPM domains found, scan exposed container ports
    if not npm_apps:
        docker_apps = get_docker_http_services()
        print(f"  • {len(docker_apps)} HTTP service(s) discovered in Docker containers.")
        candidates.extend(docker_apps)

        # Register Server-Sentry internal services
        candidates.append({
            "name": "Beszel Hub (Hardware)",
            "url": f"http://server-sentry-beszel-hub:{beszel_port}",
            "accepted_codes": '["200-299"]',
            "description": "Server-Sentry hardware telemetry dashboard"
        })
        candidates.append({
            "name": "Uptime Kuma (Status)",
            "url": f"http://127.0.0.1:{kuma_port}/dashboard",
            "accepted_codes": '["200-299","300-399"]',
            "description": "Server-Sentry service health monitor"
        })

    # 3. Idempotent insertion into Uptime Kuma
    added_count = 0
    existing_count = 0
    seen_urls = set()

    cur.execute("SELECT url FROM monitor")
    existing_urls = {r[0] for r in cur.fetchall()}

    for item in candidates:
        url = item["url"]
        name = item["name"]
        codes = item.get("accepted_codes", '["200-299"]')
        desc = item.get("description", "")

        if url in seen_urls:
            continue
        seen_urls.add(url)

        if url in existing_urls:
            existing_count += 1
            if notif_id:
                cur.execute("SELECT id FROM monitor WHERE url = ?", (url,))
                m_id = cur.fetchone()[0]
                cur.execute("INSERT OR IGNORE INTO monitor_notification (monitor_id, notification_id) VALUES (?, ?)", (m_id, notif_id))
            continue

        cur.execute("""
            INSERT INTO monitor (
                name, active, user_id, interval, url, type, weight,
                maxretries, ignore_tls, upside_down, maxredirects,
                accepted_statuscodes_json, retry_interval, method,
                expiry_notification, description, timeout
            ) VALUES (?, 1, 1, 60, ?, 'http', 2000, 1, 0, 0, 10, ?, 30, 'GET', 1, ?, 48)
        """, (name, url, codes, desc))
        m_id = cur.lastrowid
        added_count += 1

        if notif_id:
            cur.execute("INSERT OR IGNORE INTO monitor_notification (monitor_id, notification_id) VALUES (?, ?)", (m_id, notif_id))

        print(f"  ➕ New monitor registered: [{name}] -> {url}")

    conn.commit()
    conn.close()

    print(f"\n✨ Discovery completed:")
    print(f"   • {added_count} new application(s) added")
    print(f"   • {existing_count} application(s) already monitored")

    if added_count > 0:
        print("🔄 Restarting Uptime Kuma to activate newly added monitors...")
        subprocess.run(['docker', 'restart', 'server-sentry-uptime-kuma'], capture_output=True)
        print("✅ Uptime Kuma updated!")

if __name__ == '__main__':
    main()
