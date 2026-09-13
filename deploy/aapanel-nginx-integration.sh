#!/usr/bin/env bash
set -Eeuo pipefail

# Installs only a SITA-owned aaPanel extension fragment. The primary vhost,
# SSL, domain, logs, and PHP selection remain owned by aaPanel's GUI.

DOMAIN="${DOMAIN:?Isi DOMAIN sebelum memasang integrasi Nginx aaPanel}"
NGINX_CONFIG="${NGINX_CONFIG:-/www/server/panel/vhost/nginx/${DOMAIN}.conf}"
NGINX_BIN="${NGINX_BIN:-/www/server/nginx/sbin/nginx}"
MANAGE_NGINX_INTEGRATION="${MANAGE_NGINX_INTEGRATION:-true}"
VHOST_DIRECTORY="$(dirname "$NGINX_CONFIG")"
EXTENSION_DIRECTORY="${AAPANEL_NGINX_EXTENSION_DIR:-${VHOST_DIRECTORY}/extension/${DOMAIN}}"
FRAGMENT_FILE="${EXTENSION_DIRECTORY}/sita-integration.conf"
BACKUP_DIRECTORY="${AAPANEL_NGINX_BACKUP_DIR:-/var/backups/sita/nginx}"

if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
    printf 'DOMAIN tidak valid.\n' >&2
    exit 2
fi

if [[ "$NGINX_CONFIG" != /* ]] || [[ "$EXTENSION_DIRECTORY" != /* ]] || [[ "$BACKUP_DIRECTORY" != /* ]]; then
    printf 'Path konfigurasi Nginx harus absolut.\n' >&2
    exit 2
fi

case "$MANAGE_NGINX_INTEGRATION" in
    true) ;;
    false)
        printf 'Integrasi Nginx SITA dinonaktifkan oleh profile.\n'
        exit 0
        ;;
    *)
        printf 'MANAGE_NGINX_INTEGRATION harus true atau false.\n' >&2
        exit 2
        ;;
esac

run_privileged() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

run_privileged test -f "$NGINX_CONFIG" || { printf 'Vhost aaPanel tidak ditemukan: %s\n' "$NGINX_CONFIG" >&2; exit 1; }
run_privileged test -x "$NGINX_BIN" || { printf 'Binary Nginx tidak ditemukan: %s\n' "$NGINX_BIN" >&2; exit 1; }

vhost_content="$(run_privileged cat "$NGINX_CONFIG")"
expected_include="include ${VHOST_DIRECTORY}/extension/${DOMAIN}/*.conf;"
if ! grep -Fq "$expected_include" <<<"$vhost_content"; then
    printf 'Vhost tidak memuat direktori extension aaPanel yang diharapkan: %s\n' "$expected_include" >&2
    printf 'Gunakan Website > Config untuk memulihkan include bawaan aaPanel sebelum melanjutkan.\n' >&2
    exit 1
fi

temporary_file="$(mktemp)"
cleanup() { rm -f "$temporary_file"; }
trap cleanup EXIT

cat > "$temporary_file" <<'EOF'
# Managed by SITA Deployment Console. aaPanel primary vhost, SSL, and logs stay GUI-managed.
add_header X-Content-Type-Options "nosniff" always;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "camera=(), geolocation=(), microphone=()" always;

location / {
    try_files $uri $uri/ /index.php?$query_string;
}

location ~ ^/livewire(?:-|/) {
    try_files $uri $uri/ /index.php?$query_string;
}

location ^~ /storage/ {
    try_files $uri =404;
    expires 30d;
    access_log off;
    add_header Cache-Control "public, immutable";
}

location ~ ^/(app|apps)(?:/|$) {
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Port $server_port;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";
    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
    proxy_pass http://127.0.0.1:8080;
}

location ~ /\.(?!well-known).* {
    deny all;
}

location ~* ^/(?:app|bootstrap|config|database|deploy|docs|resources|routes|storage|tests|vendor)/ {
    deny all;
}
EOF

if run_privileged test -f "$FRAGMENT_FILE" && run_privileged cmp -s "$temporary_file" "$FRAGMENT_FILE"; then
    printf '[OK] Integrasi Nginx SITA sudah sinkron: %s\n' "$FRAGMENT_FILE"
    exit 0
fi

run_id="$(date -u +%Y%m%dT%H%M%SZ)"
backup_file="${BACKUP_DIRECTORY}/$(basename "$FRAGMENT_FILE").${run_id}.before-change"
run_privileged install -d -m 700 -o "$(id -un)" -g "$(id -gn)" "$BACKUP_DIRECTORY" "$EXTENSION_DIRECTORY"
had_previous=false
if run_privileged test -f "$FRAGMENT_FILE"; then
    run_privileged cp -p "$FRAGMENT_FILE" "$backup_file"
    had_previous=true
fi

run_privileged install -m 640 -o root -g root "$temporary_file" "$FRAGMENT_FILE"
if ! run_privileged "$NGINX_BIN" -t >/dev/null 2>&1; then
    if [ "$had_previous" = true ]; then
        run_privileged cp -p "$backup_file" "$FRAGMENT_FILE"
    else
        run_privileged rm -f "$FRAGMENT_FILE"
    fi
    printf 'Sintaks Nginx gagal; integrasi SITA dipulihkan.\n' >&2
    exit 1
fi
run_privileged "$NGINX_BIN" -s reload
printf '[OK] Integrasi Laravel dan Reverb dipasang: %s\n' "$FRAGMENT_FILE"
if [ "$had_previous" = true ]; then
    printf '[OK] Backup fragment sebelumnya: %s\n' "$backup_file"
fi
