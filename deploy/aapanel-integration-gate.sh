#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="${APP_DIR:-$SCRIPT_ROOT}"
cd "$PROJECT_ROOT"

DOMAIN="${DOMAIN:?Isi DOMAIN, contoh: DOMAIN=sita.kampus.ac.id bash deploy/aapanel-integration-gate.sh}"
PHP_BIN="${PHP_BIN:-php}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-}"
PHP_FPM_RUNTIME_USER="${PHP_FPM_RUNTIME_USER:-www}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${HEALTHCHECK_URL%/up}}"
HTTP_PROBE_MODE="${HTTP_PROBE_MODE:-auto}"
ORIGIN_PROBE_ADDRESS="${ORIGIN_PROBE_ADDRESS:-127.0.0.1}"
ORIGIN_PROBE_HTTP_PORT="${ORIGIN_PROBE_HTTP_PORT:-80}"
EDGE_ACCESS_POLICY="${EDGE_ACCESS_POLICY:-warn}"
CHECK_SERVICES="${CHECK_SERVICES:-true}"
CHECK_WEBSOCKET="${CHECK_WEBSOCKET:-true}"
SERVICE_READY_ATTEMPTS="${SERVICE_READY_ATTEMPTS:-10}"
SERVICE_READY_DELAY_SECONDS="${SERVICE_READY_DELAY_SECONDS:-1}"

FAILED=0
HTTP_PROBE_BASE_URL=''
HTTP_PROBE_CURL_ARGS=()
HTTP_PROBE_EFFECTIVE_MODE=''

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
    local service="$1" attempt

    for attempt in $(seq 1 "$SERVICE_READY_ATTEMPTS"); do
        if systemctl is-active --quiet "$service"; then
            ok "Service aktif: $service"
            return
        fi

        if [ "$attempt" -lt "$SERVICE_READY_ATTEMPTS" ]; then
            sleep "$SERVICE_READY_DELAY_SECONDS"
        fi
    done

    fail "Service tidak aktif setelah ${SERVICE_READY_ATTEMPTS} pemeriksaan: $service"
}

check_php_fpm() {
    local init_script="/etc/init.d/${PHP_FPM_SERVICE}" attempt

    for attempt in $(seq 1 "$SERVICE_READY_ATTEMPTS"); do
        if systemctl is-active --quiet "$PHP_FPM_SERVICE"; then
            ok "PHP-FPM aktif: $PHP_FPM_SERVICE"
            return
        fi

        # aaPanel can manage PHP-FPM through SysV while systemd reports its
        # generated compatibility unit as inactive. Its init status is the
        # authoritative health signal in that layout.
        if [ -x "$init_script" ] && "$init_script" status >/dev/null 2>&1; then
            ok "PHP-FPM aktif melalui aaPanel init script: $PHP_FPM_SERVICE"
            return
        fi

        sleep 1
    done

    fail "PHP-FPM belum aktif: $PHP_FPM_SERVICE"
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

http_status() {
    curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 "${HTTP_PROBE_CURL_ARGS[@]}" "$1" 2>/dev/null || true
}

configure_public_probe() {
    HTTP_PROBE_BASE_URL="${PUBLIC_BASE_URL%/}"
    HTTP_PROBE_CURL_ARGS=()
    HTTP_PROBE_EFFECTIVE_MODE='public'
}

configure_origin_https_probe() {
    local port=443

    [[ "$PUBLIC_BASE_URL" = https://* ]] || return 1
    if [[ "$PUBLIC_BASE_URL" =~ ^https://[^/:]+:([0-9]+) ]]; then
        port="${BASH_REMATCH[1]}"
    fi
    HTTP_PROBE_BASE_URL="${PUBLIC_BASE_URL%/}"
    HTTP_PROBE_CURL_ARGS=(--resolve "${DOMAIN}:${port}:${ORIGIN_PROBE_ADDRESS}")
    HTTP_PROBE_EFFECTIVE_MODE='origin-https'
}

configure_origin_http_probe() {
    if [[ ! "$ORIGIN_PROBE_HTTP_PORT" =~ ^[0-9]+$ ]] || [ "$ORIGIN_PROBE_HTTP_PORT" -lt 1 ] || [ "$ORIGIN_PROBE_HTTP_PORT" -gt 65535 ]; then
        return 1
    fi
    HTTP_PROBE_BASE_URL="http://${ORIGIN_PROBE_ADDRESS}:${ORIGIN_PROBE_HTTP_PORT}"
    HTTP_PROBE_CURL_ARGS=(-H "Host: ${DOMAIN}")
    HTTP_PROBE_EFFECTIVE_MODE='origin-http'
}

configure_http_probe() {
    local status

    if [ -z "$PUBLIC_BASE_URL" ] || [[ ! "$PUBLIC_BASE_URL" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/.*)?$ ]]; then
        fail "PUBLIC_BASE_URL tidak valid untuk Integration Gate: ${PUBLIC_BASE_URL:-kosong}"
        return
    fi

    case "$HTTP_PROBE_MODE" in
        public)
            configure_public_probe
            ok "Probe Integration Gate memakai jalur publik"
            ;;
        origin|origin-https)
            if ! configure_origin_https_probe; then
                fail "HTTP_PROBE_MODE=origin-https membutuhkan PUBLIC_BASE_URL HTTPS"
                return
            fi
            ok "Probe Integration Gate memakai origin HTTPS ${ORIGIN_PROBE_ADDRESS} dengan TLS/SNI ${DOMAIN}"
            ;;
        origin-http)
            if ! configure_origin_http_probe; then
                fail "HTTP_PROBE_MODE=origin-http membutuhkan port origin 1-65535"
                return
            fi
            ok "Probe Integration Gate memakai origin HTTP ${ORIGIN_PROBE_ADDRESS}:${ORIGIN_PROBE_HTTP_PORT}; cocok untuk Cloudflare Tunnel"
            ;;
        auto)
            if configure_origin_https_probe; then
                status="$(http_status "${HTTP_PROBE_BASE_URL}/up")"
                if [ "$status" = '200' ]; then
                    ok "Probe otomatis memilih origin HTTPS ${ORIGIN_PROBE_ADDRESS} dengan TLS/SNI ${DOMAIN}"
                    return
                fi
            fi
            if configure_origin_http_probe; then
                status="$(http_status "${HTTP_PROBE_BASE_URL}/up")"
                if [ "$status" = '200' ]; then
                    ok "Probe otomatis memilih origin HTTP ${ORIGIN_PROBE_ADDRESS}:${ORIGIN_PROBE_HTTP_PORT}; cocok untuk Cloudflare Tunnel"
                    return
                fi
            fi
            configure_public_probe
            ok "Probe otomatis memakai jalur publik karena origin lokal belum merespons"
            ;;
        *)
            fail "HTTP_PROBE_MODE harus auto, public, origin-https, atau origin-http"
            ;;
    esac
}

check_public_edge() {
    local status

    [ "$HTTP_PROBE_EFFECTIVE_MODE" != 'public' ] || return
    case "$EDGE_ACCESS_POLICY" in
        off) return ;;
        warn|required) ;;
        *) fail "EDGE_ACCESS_POLICY harus off, warn, atau required"; return ;;
    esac
    status="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "${PUBLIC_BASE_URL%/}/up" 2>/dev/null || true)"
    if [ "$status" = '200' ]; then
        ok "Healthcheck jalur publik tersedia"
    elif [ "$EDGE_ACCESS_POLICY" = 'required' ]; then
        fail "Healthcheck jalur publik gagal dengan HTTP ${status:-tanpa-status}"
    else
        warn "Healthcheck jalur publik belum tersedia (HTTP ${status:-tanpa-status}); aplikasi origin tetap diuji melalui ${HTTP_PROBE_EFFECTIVE_MODE}"
    fi
}

check_health() {
    if [ -z "$HTTP_PROBE_BASE_URL" ]; then
        fail "Probe HTTP belum dapat dikonfigurasi"
        return
    fi

    if [ "$(http_status "${HTTP_PROBE_BASE_URL}/up")" = '200' ]; then
        ok "Healthcheck HTTP berhasil melalui ${HTTP_PROBE_EFFECTIVE_MODE}"
    else
        fail "Healthcheck HTTP gagal melalui ${HTTP_PROBE_EFFECTIVE_MODE}"
    fi
}

check_public_storage() {
    local marker storage_url response

    marker="sita-deploy-gate-${RANDOM}-${RANDOM}.txt"
    storage_url="${HTTP_PROBE_BASE_URL}/storage/${marker}"

    if [ "$(id -un)" = "$PHP_FPM_RUNTIME_USER" ]; then
        printf '%s' "$marker" > "storage/app/public/${marker}"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -n -u "$PHP_FPM_RUNTIME_USER" sh -c 'printf "%s" "$1" > "storage/app/public/$1"' sh "$marker"
    else
        fail "Tidak dapat membuat marker sebagai user runtime PHP-FPM"
        return
    fi

    response="$(curl -kfsS --max-time 10 "${HTTP_PROBE_CURL_ARGS[@]}" "$storage_url" 2>/dev/null || true)"
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
    local app_key host port scheme protocol url status curl_exit websocket_args=()

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

    if [ "$HTTP_PROBE_EFFECTIVE_MODE" = 'origin-http' ]; then
        url="${HTTP_PROBE_BASE_URL}/app/${app_key}?protocol=7&client=sita-deploy-gate&version=1.0&flash=false"
        websocket_args=(-H "Host: ${host}")
    elif { [ "$protocol" = "https" ] && [ "$port" = "443" ]; } || { [ "$protocol" = "http" ] && [ "$port" = "80" ]; }; then
        url="${protocol}://${host}/app/${app_key}?protocol=7&client=sita-deploy-gate&version=1.0&flash=false"
        websocket_args=("${HTTP_PROBE_CURL_ARGS[@]}")
    else
        url="${protocol}://${host}:${port}/app/${app_key}?protocol=7&client=sita-deploy-gate&version=1.0&flash=false"
        websocket_args=("${HTTP_PROBE_CURL_ARGS[@]}")
    fi

    set +e
    status="$(curl -ksS -o /dev/null --max-time 5 --http1.1 -w '%{http_code}' \
        "${websocket_args[@]}" \
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
    configure_http_probe
    check_health
    check_public_storage
    check_public_edge

    if [ "$CHECK_SERVICES" = "true" ]; then
        if command -v systemctl >/dev/null 2>&1; then
            if [ -n "$PHP_FPM_SERVICE" ]; then
                check_php_fpm
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
