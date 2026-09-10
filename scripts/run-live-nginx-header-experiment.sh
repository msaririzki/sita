#!/usr/bin/env bash

# Eksperimen live Nginx hanya untuk VM lab SITA.
# Menghapus satu header sementara, memverifikasi Security Gate, lalu memulihkan konfigurasi.
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ "${SECURITY_EXPERIMENT_SCOPE:-}" != "lab" || "${ALLOW_SECURITY_EXPERIMENTS:-false}" != "true" ]]; then
    printf 'Eksperimen diblokir. Gunakan hanya pada VM lab dengan SECURITY_EXPERIMENT_SCOPE=lab dan ALLOW_SECURITY_EXPERIMENTS=true.\n' >&2
    exit 1
fi

RUNTIME="${NGINX_RUNTIME:?Isi NGINX_RUNTIME=docker atau NGINX_RUNTIME=aapanel}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:?PUBLIC_BASE_URL wajib diisi}"
REPORT_DIR="${SECURITY_EXPERIMENT_REPORT_DIR:-storage/app/security-gate-experiments}"
mkdir -p "$REPORT_DIR"

run_privileged() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

backup="$(mktemp)"
faulty="$(mktemp)"
container_id=""
restore_needed=false

restore() {
    if [[ "$restore_needed" != "true" ]]; then
        rm -f "$backup" "$faulty"
        return
    fi

    case "$RUNTIME" in
        docker)
            docker cp "$backup" "${container_id}:/etc/nginx/conf.d/default.conf"
            docker exec "$container_id" nginx -t >/dev/null
            docker exec "$container_id" nginx -s reload >/dev/null
            ;;
        aapanel)
            run_privileged cp "$backup" "$NGINX_RUNTIME_CONFIG"
            run_privileged "${NGINX_BIN:-/www/server/nginx/sbin/nginx}" -t >/dev/null
            run_privileged /etc/init.d/nginx reload >/dev/null
            ;;
    esac
    restore_needed=false
    rm -f "$backup" "$faulty"
}
trap restore EXIT

case "$RUNTIME" in
    docker)
        container_id="$(docker compose -f docker-compose.yml -f docker-compose.deploy.yml ps -q web)"
        [[ -n "$container_id" ]] || { printf 'Container web Docker tidak berjalan.\n' >&2; exit 1; }
        docker cp "${container_id}:/etc/nginx/conf.d/default.conf" "$backup"
        ;;
    aapanel)
        NGINX_RUNTIME_CONFIG="${NGINX_RUNTIME_CONFIG:?NGINX_RUNTIME_CONFIG wajib diisi untuk aaPanel}"
        [[ -f "$NGINX_RUNTIME_CONFIG" || "$EUID" -eq 0 ]] || { printf 'Vhost aaPanel tidak dapat dibaca; jalankan melalui sudo.\n' >&2; exit 1; }
        run_privileged cp "$NGINX_RUNTIME_CONFIG" "$backup"
        ;;
    *)
        printf 'NGINX_RUNTIME harus docker atau aapanel.\n' >&2
        exit 1
        ;;
esac

grep -v 'add_header X-Content-Type-Options' "$backup" > "$faulty"
grep -q 'add_header X-Content-Type-Options' "$faulty" && { printf 'Header belum berhasil dihapus dari konfigurasi eksperimen.\n' >&2; exit 1; }

restore_needed=true
case "$RUNTIME" in
    docker)
        docker cp "$faulty" "${container_id}:/etc/nginx/conf.d/default.conf"
        docker exec "$container_id" nginx -t
        docker exec "$container_id" nginx -s reload
        ;;
    aapanel)
        run_privileged cp "$faulty" "$NGINX_RUNTIME_CONFIG"
        run_privileged "${NGINX_BIN:-/www/server/nginx/sbin/nginx}" -t
        run_privileged /etc/init.d/nginx reload
        ;;
esac

log_file="${REPORT_DIR%/}/live-nginx-header-$(date -u +%Y%m%dT%H%M%SZ)-${RUNTIME}.log"
started="$(date +%s%3N)"
if SECURITY_GATE_PROFILE=production PUBLIC_BASE_URL="$PUBLIC_BASE_URL" CHECK_DOCKER=false bash scripts/security-gate.sh > "$log_file" 2>&1; then
    exit_code=0
else
    exit_code=$?
fi
duration=$(( $(date +%s%3N) - started ))

if [[ "$exit_code" -ne 0 ]] && grep -Fq 'Header X-Content-Type-Options: nosniff belum aktif.' "$log_file"; then
    detection=true
else
    detection=false
fi

restore

restored=false
for _attempt in $(seq 1 10); do
    restored_headers="$(curl -ksSI --max-time 10 "${PUBLIC_BASE_URL%/}/up" || true)"
    if grep -qi '^X-Content-Type-Options: nosniff' <<< "$restored_headers"; then
        restored=true
        break
    fi
    sleep 0.2
done

if [[ "$restored" != "true" ]]; then
    printf 'Pemulihan header Nginx tidak dapat diverifikasi.\n' >&2
    exit 1
fi

printf 'runtime=%s scenario=live_nginx_x_content_type_options_missing gate_exit=%s detected=%s duration_ms=%s\n' "$RUNTIME" "$exit_code" "$detection" "$duration"
printf 'Log: %s\n' "$log_file"

[[ "$detection" = "true" ]]
