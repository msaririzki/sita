#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

HEALTHCHECK_URL="${HEALTHCHECK_URL:?Isi HEALTHCHECK_URL, contoh: http://127.0.0.1:8088/up bash scripts/docker-integration-gate.sh}"
CHECK_WEBSOCKET="${CHECK_WEBSOCKET:-true}"

FAILED=0
compose_files=(-f docker-compose.yml -f docker-compose.deploy.yml)

ok() {
    printf '[OK] %s\n' "$1"
}

fail() {
    printf '[FAIL] %s\n' "$1"
    FAILED=1
}

compose() {
    docker compose "${compose_files[@]}" "$@"
}

env_value() {
    local key="$1"

    grep -E "^${key}=" .env | tail -n 1 | cut -d '=' -f 2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

resolved_env_value() {
    local value reference

    value="$(env_value "$1")"
    case "$value" in
        '${'*'}')
            reference="${value#\$\{}"
            reference="${reference%\}}"
            env_value "$reference"
            ;;
        *) printf '%s' "$value" ;;
    esac
}

check_running_service() {
    local service="$1" container_id

    container_id="$(compose ps -q "$service")"
    if [ -z "$container_id" ]; then
        fail "Container tidak ditemukan: $service"
        return
    fi

    if [ "$(docker inspect -f '{{.State.Running}}' "$container_id")" = "true" ]; then
        ok "Container berjalan: $service"
    else
        fail "Container tidak berjalan: $service"
    fi
}

check_healthy_service() {
    local service="$1" container_id health

    container_id="$(compose ps -q "$service")"
    if [ -z "$container_id" ]; then
        fail "Container tidak ditemukan: $service"
        return
    fi

    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")"
    if [ "$health" = "healthy" ]; then
        ok "Container sehat: $service"
    else
        fail "Health container $service: $health"
    fi
}

check_frontend_bundle() {
    local host

    host="$(resolved_env_value VITE_REVERB_HOST)"
    if [ -z "$host" ]; then
        fail "VITE_REVERB_HOST kosong"
        return
    fi

    if compose exec -T -e SITA_GATE_REVERB_HOST="$host" web sh -c 'find /var/www/html/public/build/assets -type f -name "*.js" -exec grep -F -q "$SITA_GATE_REVERB_HOST" {} \; -print -quit | grep -q .'; then
        ok "Bundle frontend memuat host Reverb"
    else
        fail "Bundle frontend tidak memuat host Reverb"
    fi
}

check_storage_route() {
    local marker storage_url response

    if ! compose exec -T web sh -c 'test -L /var/www/html/public/storage && test -d /var/www/html/public/storage'; then
        fail "Nginx web tidak dapat menyajikan public storage"
        return
    fi

    marker="sita-deploy-gate-${RANDOM}-${RANDOM}.txt"
    storage_url="${HEALTHCHECK_URL%/up}/storage/${marker}"

    if ! compose exec -T -e SITA_GATE_MARKER="$marker" app sh -c 'printf "%s" "$SITA_GATE_MARKER" > "/var/www/html/storage/app/public/$SITA_GATE_MARKER"'; then
        fail "Runtime Laravel gagal membuat marker public storage"
        return
    fi

    response="$(curl -fsS "$storage_url" 2>/dev/null || true)"
    compose exec -T -e SITA_GATE_MARKER="$marker" app sh -c 'rm -f "/var/www/html/storage/app/public/$SITA_GATE_MARKER"' || true

    if [ "$response" = "$marker" ]; then
        ok "Nginx web menyajikan public storage dari runtime Laravel"
    else
        fail "Marker public storage tidak dapat diakses melalui Nginx"
    fi
}

check_websocket_upgrade() {
    local app_key host port scheme url status curl_exit

    app_key="$(resolved_env_value VITE_REVERB_APP_KEY)"
    host="$(resolved_env_value VITE_REVERB_HOST)"
    port="$(resolved_env_value VITE_REVERB_PORT)"
    scheme="$(resolved_env_value VITE_REVERB_SCHEME)"

    if [ -z "$app_key" ] || [ -z "$host" ] || [ -z "$port" ] || [ -z "$scheme" ]; then
        fail "Konfigurasi Vite Reverb belum lengkap"
        return
    fi

    case "$scheme" in
        http|https) ;;
        *)
            fail "VITE_REVERB_SCHEME tidak didukung untuk uji HTTP upgrade: $scheme"
            return
            ;;
    esac

    if { [ "$scheme" = "https" ] && [ "$port" = "443" ]; } || { [ "$scheme" = "http" ] && [ "$port" = "80" ]; }; then
        url="${scheme}://${host}/app/${app_key}?protocol=7&client=sita-deploy-gate&version=1.0&flash=false"
    else
        url="${scheme}://${host}:${port}/app/${app_key}?protocol=7&client=sita-deploy-gate&version=1.0&flash=false"
    fi

    set +e
    status="$(curl -sS -o /dev/null --max-time 5 --http1.1 -w '%{http_code}' \
        -H 'Connection: Upgrade' \
        -H 'Upgrade: websocket' \
        -H 'Sec-WebSocket-Version: 13' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        "$url" 2>/dev/null)"
    curl_exit=$?
    set -e

    if [ "$status" = "101" ]; then
        ok "WebSocket upgrade Reverb berhasil"
    else
        fail "WebSocket upgrade gagal dengan HTTP ${status:-tanpa-status} (curl exit ${curl_exit})"
    fi
}

printf 'SITA Docker integration gate\n'
printf 'Project root: %s\n\n' "$PROJECT_ROOT"

if ! command -v docker >/dev/null 2>&1; then
    fail "docker tidak tersedia"
fi

if ! command -v curl >/dev/null 2>&1; then
    fail "curl tidak tersedia"
fi

if [ ! -f .env ]; then
    fail ".env tidak ditemukan"
fi

if [ "$FAILED" -eq 0 ]; then
    for service in db app web queue scheduler reverb; do
        check_running_service "$service"
    done

    check_healthy_service db
    check_healthy_service app

    if compose exec -T app sh -c 'test -w /var/www/html/storage'; then
        ok "Runtime Laravel dapat menulis storage"
    else
        fail "Runtime Laravel tidak dapat menulis storage"
    fi

    if curl -fsS "$HEALTHCHECK_URL" >/dev/null; then
        ok "Healthcheck HTTP berhasil: $HEALTHCHECK_URL"
    else
        fail "Healthcheck HTTP gagal: $HEALTHCHECK_URL"
    fi

    if [ "$(env_value BROADCAST_CONNECTION)" = "reverb" ]; then
        check_storage_route
        check_frontend_bundle

        if [ "$CHECK_WEBSOCKET" = "true" ]; then
            check_websocket_upgrade
        fi
    fi
fi

if [ "$FAILED" -eq 0 ]; then
    printf '\nIntegration gate lulus.\n'
else
    printf '\nIntegration gate gagal. Perbaiki item [FAIL] sebelum deployment dinyatakan siap.\n'
fi

exit "$FAILED"
