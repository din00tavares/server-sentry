#!/usr/bin/env python3
# ==============================================================================
# SERVER-SENTRY: Dynamic Uptime Kuma Populator & Synchronizer
# ==============================================================================
# 100% Generic and Autonomous:
# 1. Dynamically discovers proxy domains configured in Nginx Proxy Manager.
# 2. Dynamically discovers Docker services with published web ports (handling port ranges).
# 3. Dynamically discovers background Docker worker containers & bots (Docker socket monitoring).
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
    """Discovers all active proxy domains and upstream targets from Nginx Proxy Manager."""
    discovered = []
    upstream_servers = set()
    try:
        res = subprocess.run(
            ['docker', 'ps', '--filter', 'name=nginx-proxy-manager', '--format', '{{.Names}}'],
            capture_output=True, text=True, check=True
        )
        npm_name = res.stdout.strip().split('\n')[0]
        if not npm_name:
            return discovered, upstream_servers

        files_out = subprocess.run(
            ['docker', 'exec', npm_name, 'sh', '-c', 'ls -1 /data/nginx/proxy_host/*.conf 2>/dev/null'],
            capture_output=True, text=True
        )
        conf_files = files_out.stdout.strip().split()

        for conf_file in conf_files:
            cat_cmd = f"cat {conf_file}"
            c = subprocess.run(['docker', 'exec', npm_name, 'sh', '-c', cat_cmd], capture_output=True, text=True)
            content = c.stdout

            # Extract upstream server/target if present
            m_server = re.findall(r'set\s+\$server\s+["\']?([^"\';]+)["\']?;', content)
            for s in m_server:
                upstream_servers.add(s.strip().lower())

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
                    "type": "http",
                    "url": f"{scheme}://{domain}",
                    "accepted_codes": '["200-299","300-399","404"]' if 'api' in domain else '["200-299","300-399"]',
                    "description": f"Automatically discovered via Nginx Proxy Manager ({domain})"
                })
    except Exception as e:
        print(f"ℹ️  No domains extracted from NPM: {e}")

    return discovered, upstream_servers

def get_docker_http_services(upstream_servers):
    """Discovers Docker containers with published web ports on the host."""
    discovered = []
    covered_containers = set()

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

            # Exclude internal sentry and proxy manager containers
            if 'server-sentry' in name or 'nginx-proxy-manager' in name:
                continue

            # Support both single port and port ranges e.g. 127.0.0.1:6333-6334->6333-6334/tcp
            matches = re.findall(r'(?:0\.0\.0\.0|127\.0\.0\.1):(\d+(?:-\d+)?)->(\d+(?:-\d+)?)/tcp', ports_raw)
            if not matches:
                continue

            # Check if this container is already proxied via NPM
            clean_name = name.lower()
            if any(srv in clean_name for srv in upstream_servers):
                covered_containers.add(name)
                continue

            for host_port_range, cont_port_range in matches:
                primary_port_str = host_port_range.split('-')[0]
                p = int(primary_port_str)
                # Ignore non-web internal infra ports
                if p in [80, 443, 22, 25, 465, 587, 993, 4190, 27017, 6379, 5432, 5433, 5434]:
                    continue

                friendly_name = name.replace('-', ' ').replace('_', ' ').title()
                discovered.append({
                    "name": f"{friendly_name} (Port {p})",
                    "type": "http",
                    "url": f"http://127.0.0.1:{p}",
                    "accepted_codes": '["200-299","300-399","401","404"]',
                    "description": f"Docker container service detected on host port {p} ({name})"
                })
                covered_containers.add(name)
                break # Monitor primary exposed port

    except Exception as e:
        print(f"ℹ️  Warning while scanning Docker ports: {e}")

    return discovered, covered_containers

def get_docker_worker_containers(covered_containers, docker_host_id):
    """Discovers background containers and bots without exposed web ports."""
    discovered = []
    try:
        res = subprocess.run(
            ['docker', 'ps', '--format', '{{.Names}}'],
            capture_output=True, text=True, check=True
        )
        for line in res.stdout.strip().split('\n'):
            name = line.strip()
            if not name:
                continue

            if 'server-sentry' in name or 'nginx-proxy-manager' in name:
                continue

            if name in covered_containers:
                continue

            friendly_name = name.replace('-', ' ').replace('_', ' ').title()
            discovered.append({
                "name": f"{friendly_name} (Container)",
                "type": "docker",
                "docker_host": docker_host_id,
                "docker_container": name,
                "url": None,
                "description": f"Autonomous Docker container health monitor for {name}"
            })
    except Exception as e:
        print(f"ℹ️  Warning while scanning Docker worker containers: {e}")

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

    # 2. Ensure Local Docker Daemon Host is configured for Docker-type monitors
    cur.execute("SELECT id FROM docker_host WHERE docker_daemon = '/var/run/docker.sock'")
    row = cur.fetchone()
    if not row:
        cur.execute("INSERT INTO docker_host (user_id, docker_daemon, docker_type, name) VALUES (1, '/var/run/docker.sock', 'socket', 'Local Docker Daemon')")
        docker_host_id = cur.lastrowid
    else:
        docker_host_id = row[0]

    # 3. Dynamic Discovery
    print("\n🔍 Initiating dynamic service discovery...")
    candidates = []

    # A. Public domains from Nginx Proxy Manager
    npm_apps, upstream_servers = get_npm_domains()
    print(f"  • {len(npm_apps)} domain(s) discovered in Nginx Proxy Manager.")
    candidates.extend(npm_apps)

    # B. Exposed container ports (handling ranges e.g. 6333-6334)
    docker_apps, covered_containers = get_docker_http_services(upstream_servers)
    print(f"  • {len(docker_apps)} standalone HTTP service(s) discovered on host ports.")
    candidates.extend(docker_apps)

    # C. Background workers, bots & daemon containers without web ports
    worker_apps = get_docker_worker_containers(covered_containers, docker_host_id)
    print(f"  • {len(worker_apps)} background container(s)/bot(s) discovered for Docker monitoring.")
    candidates.extend(worker_apps)

    # 4. Idempotent insertion into Uptime Kuma
    added_count = 0
    existing_count = 0

    cur.execute("SELECT url, docker_container, name FROM monitor")
    existing_records = cur.fetchall()
    existing_urls = {r[0] for r in existing_records if r[0]}
    existing_containers = {r[1] for r in existing_records if r[1]}
    existing_names = {r[2] for r in existing_records if r[2]}

    for item in candidates:
        m_type = item.get("type", "http")
        name = item["name"]
        desc = item.get("description", "")

        if m_type == "http":
            url = item["url"]
            codes = item.get("accepted_codes", '["200-299"]')

            if url in existing_urls or name in existing_names:
                existing_count += 1
                if notif_id:
                    cur.execute("SELECT id FROM monitor WHERE url = ? OR name = ?", (url, name))
                    m_row = cur.fetchone()
                    if m_row:
                        cur.execute("INSERT OR IGNORE INTO monitor_notification (monitor_id, notification_id) VALUES (?, ?)", (m_row[0], notif_id))
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

            print(f"  ➕ New HTTP monitor registered: [{name}] -> {url}")

        elif m_type == "docker":
            container_name = item["docker_container"]
            d_host = item["docker_host"]

            if container_name in existing_containers or name in existing_names:
                existing_count += 1
                if notif_id:
                    cur.execute("SELECT id FROM monitor WHERE docker_container = ? OR name = ?", (container_name, name))
                    m_row = cur.fetchone()
                    if m_row:
                        cur.execute("INSERT OR IGNORE INTO monitor_notification (monitor_id, notification_id) VALUES (?, ?)", (m_row[0], notif_id))
                continue

            cur.execute("""
                INSERT INTO monitor (
                    name, active, user_id, interval, type, weight,
                    maxretries, retry_interval, docker_host, docker_container,
                    description, timeout
                ) VALUES (?, 1, 1, 60, 'docker', 2000, 1, 30, ?, ?, ?, 48)
            """, (name, d_host, container_name, desc))
            m_id = cur.lastrowid
            added_count += 1

            if notif_id:
                cur.execute("INSERT OR IGNORE INTO monitor_notification (monitor_id, notification_id) VALUES (?, ?)", (m_id, notif_id))

            print(f"  ➕ New Docker container monitor registered: [{name}] -> {container_name}")

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
