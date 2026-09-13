#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="${SERVICE_WORKING_DIR:-$SCRIPT_ROOT}"
cd "$SCRIPT_ROOT"

DOMAIN="${DOMAIN:?Isi DOMAIN, contoh: DOMAIN=sita.kampus.ac.id bash deploy/aapanel-services.sh}"
PHP_BIN="${PHP_BIN:-/www/server/php/84/bin/php}"
PHP_FPM_RUNTIME_USER="${PHP_FPM_RUNTIME_USER:-www}"
SERVICE_USER="${SERVICE_USER:-$PHP_FPM_RUNTIME_USER}"
SERVICE_GROUP="${SERVICE_GROUP:-www}"
REVERB_HOST="${REVERB_SERVER_HOST:-127.0.0.1}"
REVERB_PORT="${REVERB_SERVER_PORT:-8080}"
QUEUE_SLEEP="${QUEUE_SLEEP:-1}"
QUEUE_TRIES="${QUEUE_TRIES:-3}"
QUEUE_TIMEOUT="${QUEUE_TIMEOUT:-90}"

if ! command -v systemctl >/dev/null 2>&1; then
    printf 'systemctl tidak tersedia. Gunakan aaPanel Process Manager/Supervisor dengan command di docs.\n' >&2
    exit 1
fi

run_privileged() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
        return
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
        return
    fi

    printf 'Hak root diperlukan untuk memasang service. Jalankan sebagai root atau sediakan sudo.\n' >&2
    exit 1
}

if ! getent passwd "$SERVICE_USER" >/dev/null 2>&1; then
    printf 'User runtime service tidak ditemukan: %s\n' "$SERVICE_USER" >&2
    exit 1
fi

if ! getent group "$SERVICE_GROUP" >/dev/null 2>&1; then
    printf 'Group runtime service tidak ditemukan: %s\n' "$SERVICE_GROUP" >&2
    exit 1
fi

SERVICE_SLUG="$(printf '%s' "$DOMAIN" | tr -cs 'A-Za-z0-9' '-')"
REVERB_SERVICE="sita-${SERVICE_SLUG}-reverb.service"
QUEUE_SERVICE="sita-${SERVICE_SLUG}-queue.service"
SCHEDULER_SERVICE="sita-${SERVICE_SLUG}-schedule.service"
SCHEDULER_TIMER="sita-${SERVICE_SLUG}-schedule.timer"

write_unit() {
    local path="$1"
    run_privileged tee "$path" >/dev/null
}

printf 'Membuat systemd service untuk %s\n' "$DOMAIN"

write_unit "/etc/systemd/system/${REVERB_SERVICE}" <<EOF
[Unit]
Description=SITA Reverb WebSocket (${DOMAIN})
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${PROJECT_ROOT}
Environment=PATH=$(dirname "$PHP_BIN"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${PHP_BIN} artisan reverb:start --host=${REVERB_HOST} --port=${REVERB_PORT}
Restart=always
RestartSec=3
KillSignal=SIGTERM
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF

write_unit "/etc/systemd/system/${QUEUE_SERVICE}" <<EOF
[Unit]
Description=SITA Laravel Queue Worker (${DOMAIN})
After=network.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${PROJECT_ROOT}
Environment=PATH=$(dirname "$PHP_BIN"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${PHP_BIN} artisan queue:work database --sleep=${QUEUE_SLEEP} --tries=${QUEUE_TRIES} --timeout=${QUEUE_TIMEOUT}
Restart=always
RestartSec=3
KillSignal=SIGTERM
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
EOF

write_unit "/etc/systemd/system/${SCHEDULER_SERVICE}" <<EOF
[Unit]
Description=SITA Laravel Scheduler (${DOMAIN})

[Service]
Type=oneshot
User=${SERVICE_USER}
Group=${SERVICE_GROUP}
WorkingDirectory=${PROJECT_ROOT}
Environment=PATH=$(dirname "$PHP_BIN"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${PHP_BIN} artisan schedule:run
EOF

write_unit "/etc/systemd/system/${SCHEDULER_TIMER}" <<EOF
[Unit]
Description=Run SITA Laravel Scheduler every minute (${DOMAIN})

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=1
Unit=${SCHEDULER_SERVICE}

[Install]
WantedBy=timers.target
EOF

run_privileged systemctl daemon-reload
run_privileged systemctl enable "$REVERB_SERVICE" "$QUEUE_SERVICE"
run_privileged systemctl enable --now "$SCHEDULER_TIMER"
run_privileged systemctl reset-failed "$REVERB_SERVICE" "$QUEUE_SERVICE"
run_privileged systemctl restart "$REVERB_SERVICE" "$QUEUE_SERVICE"

printf '\nService aktif:\n'
run_privileged systemctl --no-pager --full status "$REVERB_SERVICE" "$QUEUE_SERVICE" "$SCHEDULER_TIMER" || true

printf '\nCek ringkas:\n'
systemctl is-active "$REVERB_SERVICE" || true
systemctl is-active "$QUEUE_SERVICE" || true
systemctl is-active "$SCHEDULER_TIMER" || true
