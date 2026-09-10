#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

DOMAIN="${DOMAIN:?Isi DOMAIN, contoh: DOMAIN=sita.kampus.ac.id bash deploy/aapanel-integration-gate.sh}"
PHP_BIN="${PHP_BIN:-php}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-}"
PHP_FPM_RUNTIME_USER="${PHP_FPM_RUNTIME_USER:-www}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
CHECK_SERVICES="${CHECK_SERVICES:-true}"
CHECK_WEBSOCKET="${CHECK_WEBSOCKET:-true}"

FAILED=0

ok() {
    printf '[OK] %s\n' "$1"
}

warn() {
    printf '[WARN] %s\n' "$1"
}

fail() {
    printf '[FAIL] %s\n' "$1"
    FAILED=1
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

service_slug() {
    printf '%s' "$DOMAIN" | tr -cs 'A-Za-z0-9' '-'
}

check_service() {
    local service="$1"

    if systemctl is-active --quiet "$service"; then
        ok "Service aktif: $service"
    else
        fail "Service tidak aktif: $service"
    fi
}

check_runtime_write_access() {
    local dir

    for dir in storage bootstrap/cache; do
        if [ ! -d "$dir" ]; then
            fail "Folder runtime tidak ditemukan: $dir"
            continue
        fi

        if [ "$(id -un)" = "$PHP_FPM_RUNTIME_USER" ]; then
            [ -w "$dir" ] && ok "User runtime dapat menulis: $dir" || fail "User runtime tidak dapat menulis: $dir"
        elif command -v sudo >/dev/null 2>&1 && sudo -n -u "$PHP_FPM_RUNTIME_USER" test -w "$dir"; then
            ok "User runtime ${PHP_FPM_RUNTIME_USER} dapat menulis: $dir"
        else
            fail "User runtime ${PHP_FPM_RUNTIME_USER} tidak dapat menulis: $dir"
        fi
    done
}

check_health() {
    if [ -z "$HEALTHCHECK_URL" ]; then
        fail "HEALTHCHECK_URL wajib untuk integration gate"
        return
    fi

    if curl -fsS "$HEALTHCHECK_URL" >/dev/null; then
        ok "Healthcheck HTTP berhasil: $HEALTHCHECK_URL"
    else
        fail "Healthcheck HTTP gagal: $HEALTHCHECK_URL"
    fi
}

check_public_storage() {
    local marker storage_url response

    marker=".sita-deploy-gate-${RANDOM}-${RANDOM}.txt"
    storage_url="${HEALTHCHECK_URL%/up}/storage/${marker}"

    if [ "$(id -un)" = "$PHP_FPM_RUNTIME_USER" ]; then
        printf '%s' "$marker" > "storage/app/public/${marker}"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n -u "$PHP_FPM_RUNTIME_USER" sh -c 'printf "%s" "$1" > "storage/app/public/$1"' sh "$marker"
    else
        fail "Tidak dapat membuat marker sebagai user runtime PHP-FPM"
        return
    fi

    response="$(curl -fsS "$storage_url" 2>/dev/null || true)"
    rm -f "storage/app/public/${marker}"

    if [ "$response" = "$marker" ]; then
        ok "Nginx menyajikan public storage dari runtime Laravel"
    else
        fail "Marker public storage tidak dapat diakses melalui Nginx"
    fi
}

check_frontend_reverb_bundle() {
    local host

    host="$(resolved_env_value VITE_REVERB_HOST)"
    if [ -z "$host" ]; then
        fail "VITE_REVERB_HOST kosong"
        return
    fi

    if [ ! -d public/build/assets ]; then
        fail "Asset build production belum tersedia"
        return
    fi

    if grep -R -F -q --include='*.js' "$host" public/build/assets; then
        ok "Bundle frontend memuat host Reverb"
    else
        fail "Bundle frontend tidak memuat host Reverb"
    fi
}

check_websocket_upgrade() {
    local app_key host port scheme protocol url status curl_exit

    app_key="$(env_value REVERB_APP_KEY)"
    host="$(env_value REVERB_HOST)"
    port="$(env_value REVERB_PORT)"
    scheme="$(env_value REVERB_SCHEME)"

    if [ -z "$app_key" ] || [ -z "$host" ] || [ -z "$port" ] || [ -z "$scheme" ]; then
        fail "Konfigurasi Reverb browser belum lengkap"
        return
    fi

    case "$scheme" in
        http|https) protocol="$scheme" ;;
        *)
            fail "REVERB_SCHEME tidak didukung untuk uji HTTP upgrade: $scheme"
            return
            ;;
    esac

    if { [ "$protocol" = "https" ] && [ "$port" = "443" ]; } || { [ "$protocol" = "http" ] && [ "$port" = "80" ]; }; then
        url="${protocol}://${host}/app/${app_key}?protocol=7&client=sita-deploy-gate&version=1.0&flash=false"
    else
        url="${protocol}://${host}:${port}/app/${app_key}?protocol=7&client=sita-deploy-gate&version=1.0&flash=false"
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
        ok "WebSocket upgrade Nginx/Reverb berhasil"
    else
        fail "WebSocket upgrade gagal dengan HTTP ${status:-tanpa-status} (curl exit ${curl_exit})"
    fi
}

printf 'SITA aaPanel integration gate\n'
printf 'Project root: %s\n' "$PROJECT_ROOT"
printf 'Domain: %s\n\n' "$DOMAIN"

if [ ! -f .env ]; then
    fail ".env tidak ditemukan"
fi

if ! command -v curl >/dev/null 2>&1; then
    fail "curl tidak tersedia"
fi

if ! command -v "$PHP_BIN" >/dev/null 2>&1; then
    fail "PHP tidak tersedia: $PHP_BIN"
fi

if [ -f .env ]; then
    check_runtime_write_access
    check_health
    check_public_storage

    if [ "$CHECK_SERVICES" = "true" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            if [ -n "$PHP_FPM_SERVICE" ]; then
                check_service "$PHP_FPM_SERVICE"
            else
                warn "PHP_FPM_SERVICE kosong; lewati cek service PHP-FPM"
            fi

            slug="$(service_slug)"
            check_service "sita-${slug}-reverb.service"
            check_service "sita-${slug}-queue.service"
            check_service "sita-${slug}-schedule.timer"
        else
            fail "systemctl tidak tersedia untuk memeriksa service"
        fi
    fi

    if [ "$(env_value BROADCAST_CONNECTION)" = "reverb" ]; then
        check_frontend_reverb_bundle

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
