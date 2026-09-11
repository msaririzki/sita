#!/usr/bin/env bash

# Security gate ringan tanpa dependency baru untuk deployment SITA.
# Jalankan dari root proyek. Nilai .env tidak pernah dicetak.
set -Eeuo pipefail

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_ROOT="${APP_DIR:-$SCRIPT_ROOT}"
cd "$PROJECT_ROOT"

PROFILE="${SECURITY_GATE_PROFILE:-production}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
NGINX_CONFIG="${NGINX_CONFIG:-}"
CHECK_HTTP="${CHECK_HTTP:-true}"
CHECK_DOCKER="${CHECK_DOCKER:-true}"
HTTP_PROBE_MODE="${HTTP_PROBE_MODE:-auto}"
ORIGIN_PROBE_ADDRESS="${ORIGIN_PROBE_ADDRESS:-127.0.0.1}"
ORIGIN_PROBE_HTTP_PORT="${ORIGIN_PROBE_HTTP_PORT:-80}"
CHECK_EDGE_HTTP="${CHECK_EDGE_HTTP:-false}"

HTTP_PROBE_BASE_URL=''
HTTP_PROBE_PUBLIC_BASE_URL=''
HTTP_PROBE_EFFECTIVE_MODE=''
HTTP_PROBE_CURL_ARGS=()

failures=0
warnings=0

pass() { printf 'PASS  %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; warnings=$((warnings + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; failures=$((failures + 1)); }

env_value() {
    local key="$1"
    awk -F= -v key="$key" '
        $1 == key { value = substr($0, length(key) + 2) }
        END {
            gsub(/^"|"$/, "", value)
            gsub(/^\047|\047$/, "", value)
            print value
        }
    ' .env
}

require_env_value() {
    local key="$1" value
    value="$(env_value "$key")"
    if [[ -z "$value" ]]; then
        fail "$key harus terisi."
        return
    fi
    pass "$key terisi."
}

check_production_configuration() {
    local app_env app_debug log_level reverb_origins
    app_env="$(env_value APP_ENV)"
    app_debug="$(env_value APP_DEBUG)"
    log_level="$(env_value LOG_LEVEL)"
    reverb_origins="$(env_value REVERB_ALLOWED_ORIGINS)"

    if [[ "$PROFILE" = "production" && "$app_env" != "production" ]]; then fail "APP_ENV harus production pada profile production."; else pass "APP_ENV sesuai profile $PROFILE."; fi
    if [[ "$PROFILE" = "production" && "$app_debug" != "false" ]]; then fail "APP_DEBUG harus false pada profile production."; else pass "APP_DEBUG aman untuk profile $PROFILE."; fi
    if [[ "$PROFILE" = "production" && "${log_level,,}" = "debug" ]]; then fail "LOG_LEVEL tidak boleh debug pada profile production. Gunakan info atau warning."; else pass "LOG_LEVEL aman untuk profile $PROFILE."; fi

    require_env_value APP_KEY
    require_env_value REVERB_APP_KEY
    require_env_value REVERB_APP_SECRET

    if [[ "$PROFILE" = "production" && ( -z "$reverb_origins" || "$reverb_origins" = *"*"* || "$reverb_origins" = *"://"* ) ]]; then
        fail "REVERB_ALLOWED_ORIGINS harus berisi hostname eksplisit tanpa skema URL dan tanpa wildcard pada production."
    else
        pass "REVERB_ALLOWED_ORIGINS memakai hostname eksplisit tanpa wildcard."
    fi
}

check_env_permission() {
    local mode other group
    if ! command -v stat >/dev/null 2>&1; then warn "stat tidak tersedia; permission .env tidak diperiksa."; return; fi
    # Atomic releases expose shared .env through a symlink. Inspect the target
    # file permission, not the conventional 777 mode of the symlink itself.
    mode="$(stat -Lc '%a' .env 2>/dev/null || true)"
    if [[ ! "$mode" =~ ^[0-7]{3,4}$ ]]; then warn "Mode .env tidak dapat dibaca; permission tidak diperiksa."; return; fi
    mode="${mode: -3}"; group="${mode:1:1}"; other="${mode:2:1}"
    if (( other != 0 )); then fail ".env dapat diakses oleh pengguna lain (mode $mode). Gunakan paling ketat 640."; else pass ".env tidak dapat diakses oleh pengguna lain (mode $mode)."; fi
    if (( (group & 2) != 0 )); then warn "Group dapat menulis .env (mode $mode); batasi bila tidak dibutuhkan."; fi
}

check_compiled_assets() {
    local hits
    if [[ -d public/build ]]; then
        hits="$(grep -R -I -l -E 'APP_KEY=|DB_PASSWORD=|REVERB_APP_SECRET=' public/build 2>/dev/null || true)"
        if [[ -n "$hits" ]]; then fail "Artefak frontend memuat pola rahasia server."; else pass "Artefak frontend tidak memuat pola rahasia server."; fi
        return
    fi

    if [[ "$CHECK_DOCKER" = "true" ]] && command -v docker >/dev/null 2>&1 && docker compose -f docker-compose.yml -f docker-compose.deploy.yml exec -T app test -d /var/www/html/public/build >/dev/null 2>&1; then
        if docker compose -f docker-compose.yml -f docker-compose.deploy.yml exec -T app sh -c "! grep -R -I -l -E 'APP_KEY=|DB_PASSWORD=|REVERB_APP_SECRET=' /var/www/html/public/build >/dev/null 2>&1"; then
            pass "Artefak frontend container tidak memuat pola rahasia server."
        else
            fail "Artefak frontend container memuat pola rahasia server."
        fi
        return
    fi

    warn "public/build belum ada dan container aplikasi tidak dapat diperiksa."
}

configure_http_probe() {
    local authority host path port scheme status

    if [[ "$CHECK_HTTP" != "true" ]]; then
        return
    fi
    if [[ -z "$PUBLIC_BASE_URL" ]]; then
        fail "PUBLIC_BASE_URL wajib diisi agar endpoint HTTP dapat diperiksa."
        return
    fi

    HTTP_PROBE_PUBLIC_BASE_URL="${PUBLIC_BASE_URL%/}"
    if [[ ! "$HTTP_PROBE_PUBLIC_BASE_URL" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/.*)?$ ]]; then
        fail "PUBLIC_BASE_URL harus berupa URL HTTP(S) dengan hostname dan port opsional yang valid."
        return
    fi

    scheme="${HTTP_PROBE_PUBLIC_BASE_URL%%://*}"
    authority="${HTTP_PROBE_PUBLIC_BASE_URL#*://}"
    authority="${authority%%/*}"
    path="${HTTP_PROBE_PUBLIC_BASE_URL#*://}"
    if [[ "$path" = */* ]]; then
        path="/${path#*/}"
    else
        path=''
    fi
    host="${authority%%:*}"
    port=80
    if [[ "$scheme" = 'https' ]]; then
        port=443
    fi
    if [[ "$authority" = *:* ]]; then
        port="${authority##*:}"
    fi
    if [[ ! "$host" =~ ^[A-Za-z0-9.-]+$ ]] || [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); then
        fail "Hostname atau port pada PUBLIC_BASE_URL tidak valid."
        return
    fi

    configure_public_probe() {
        HTTP_PROBE_BASE_URL="$HTTP_PROBE_PUBLIC_BASE_URL"
        HTTP_PROBE_CURL_ARGS=()
        HTTP_PROBE_EFFECTIVE_MODE='public'
        pass "Probe HTTP memakai jalur publik."
    }

    configure_origin_https_probe() {
        if [[ "$scheme" != 'https' ]]; then
            return 1
        fi
        HTTP_PROBE_BASE_URL="$HTTP_PROBE_PUBLIC_BASE_URL"
        HTTP_PROBE_CURL_ARGS=(--resolve "${host}:${port}:${ORIGIN_PROBE_ADDRESS}")
        HTTP_PROBE_EFFECTIVE_MODE='origin-https'
        return 0
    }

    configure_origin_http_probe() {
        if [[ ! "$ORIGIN_PROBE_HTTP_PORT" =~ ^[0-9]{1,5}$ ]] || (( ORIGIN_PROBE_HTTP_PORT < 1 || ORIGIN_PROBE_HTTP_PORT > 65535 )); then
            return 1
        fi
        HTTP_PROBE_BASE_URL="http://${ORIGIN_PROBE_ADDRESS}:${ORIGIN_PROBE_HTTP_PORT}${path}"
        HTTP_PROBE_CURL_ARGS=(-H "Host: ${authority}")
        HTTP_PROBE_EFFECTIVE_MODE='origin-http'
        return 0
    }

    origin_https_is_healthy() {
        configure_origin_https_probe || return 1
        status="$(http_status "${HTTP_PROBE_BASE_URL}/up")"
        [[ "$status" =~ ^2[0-9]{2}$ ]]
    }

    origin_http_is_healthy() {
        configure_origin_http_probe || return 1
        status="$(http_status "${HTTP_PROBE_BASE_URL}/up")"
        [[ "$status" =~ ^2[0-9]{2}$ ]]
    }

    case "$HTTP_PROBE_MODE" in
        public)
            configure_public_probe
            ;;
        origin|origin-https)
            if [[ "$scheme" != 'https' ]] || [[ -z "$ORIGIN_PROBE_ADDRESS" ]]; then
                fail "HTTP_PROBE_MODE=origin-https membutuhkan PUBLIC_BASE_URL HTTPS dan ORIGIN_PROBE_ADDRESS."
                return
            fi
            configure_origin_https_probe
            pass "Probe HTTP memakai origin ${ORIGIN_PROBE_ADDRESS} dengan hostname TLS ${host}."
            ;;
        origin-http)
            if [[ -z "$ORIGIN_PROBE_ADDRESS" ]] || ! configure_origin_http_probe; then
                fail "HTTP_PROBE_MODE=origin-http membutuhkan ORIGIN_PROBE_ADDRESS dan ORIGIN_PROBE_HTTP_PORT 1-65535."
                return
            fi
            pass "Probe HTTP memakai origin HTTP ${ORIGIN_PROBE_ADDRESS}:${ORIGIN_PROBE_HTTP_PORT} dengan Host ${authority}."
            ;;
        auto)
            if [[ -z "$ORIGIN_PROBE_ADDRESS" ]]; then
                fail "HTTP_PROBE_MODE=auto membutuhkan ORIGIN_PROBE_ADDRESS."
                return
            fi
            if origin_https_is_healthy; then
                pass "Probe otomatis memilih origin HTTPS ${ORIGIN_PROBE_ADDRESS} dengan TLS/SNI ${host}."
            elif origin_http_is_healthy; then
                pass "Probe otomatis memilih origin HTTP ${ORIGIN_PROBE_ADDRESS}:${ORIGIN_PROBE_HTTP_PORT} dengan Host ${authority}; cocok untuk Cloudflare Tunnel."
            else
                configure_public_probe
                status="$(http_status "${HTTP_PROBE_BASE_URL}/up")"
                if [[ "$status" =~ ^2[0-9]{2}$ ]]; then
                    pass "Probe otomatis memakai jalur publik karena origin lokal tidak merespons healthcheck."
                else
                    fail "Probe otomatis tidak menemukan origin HTTPS, origin HTTP, atau jalur publik yang sehat (healthcheck terakhir HTTP ${status:-tidak ada respons})."
                fi
            fi
            ;;
        *)
            fail "HTTP_PROBE_MODE harus auto, public, origin-https, atau origin-http."
            ;;
    esac
}

http_status() { curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 "${HTTP_PROBE_CURL_ARGS[@]}" "$1" 2>/dev/null || true; }

http_headers() { curl -ksS -D - -o /dev/null --max-time 10 "${HTTP_PROBE_CURL_ARGS[@]}" "$1" 2>/dev/null || true; }

check_edge_http() {
    local headers server status
    if [[ "$CHECK_EDGE_HTTP" != "true" || "$CHECK_HTTP" != "true" || -z "$HTTP_PROBE_PUBLIC_BASE_URL" || "$HTTP_PROBE_EFFECTIVE_MODE" = 'public' ]]; then
        return
    fi
    headers="$(curl -ksS -D - -o /dev/null -w '\n%{http_code}' --max-time 10 "${HTTP_PROBE_PUBLIC_BASE_URL}/up" 2>/dev/null || true)"
    status="${headers##*$'\n'}"
    server="$(header_value "$headers" 'Server')"
    if [[ "$status" = '403' && "${server,,}" = *cloudflare* ]]; then
        warn "Cloudflare/WAF menampilkan verifikasi bot pada jalur publik; pemeriksaan aplikasi dilakukan melalui origin lokal."
    elif [[ "$status" = '200' ]]; then
        pass "Jalur publik dapat mengakses health endpoint (HTTP 200)."
    elif [[ "$status" =~ ^[0-9]{3}$ ]]; then
        warn "Jalur publik menghasilkan HTTP $status; periksa aturan Cloudflare/WAF tanpa melemahkan proteksinya."
    else
        warn "Jalur publik tidak dapat diperiksa."
    fi
}

check_public_exposure() {
    local path status
    if [[ "$CHECK_HTTP" != "true" ]]; then warn "Pemeriksaan HTTP dinonaktifkan."; return; fi
    if [[ -z "$HTTP_PROBE_BASE_URL" ]]; then return; fi
    for path in '/.env' '/.git/HEAD' '/composer.lock'; do
        status="$(http_status "${HTTP_PROBE_BASE_URL}${path}")"
        if [[ ! "$status" =~ ^[0-9]{3}$ ]]; then fail "Endpoint sensitif $path tidak dapat diperiksa.";
        elif (( status >= 200 && status < 400 )); then fail "Endpoint sensitif $path terbuka (HTTP $status).";
        else pass "Endpoint sensitif $path tidak terbuka (HTTP $status)."; fi
    done
}

header_value() {
    local headers="$1" header="$2"
    printf '%s\n' "$headers" | awk -F: -v header="$header" '
        tolower($1) == tolower(header) { value = substr($0, index($0, ":") + 1); gsub(/^[[:space:]]+|\r$/, "", value); print value }
    ' | tail -n 1
}

check_security_headers() {
    local headers value
    if [[ "$CHECK_HTTP" != "true" || -z "$HTTP_PROBE_BASE_URL" ]]; then return; fi
    headers="$(http_headers "${HTTP_PROBE_BASE_URL}/up")"
    if [[ -z "$headers" ]]; then fail "Header keamanan tidak dapat diperiksa pada endpoint /up."; return; fi
    value="$(header_value "$headers" 'X-Content-Type-Options')"; [[ "${value,,}" = "nosniff" ]] && pass "X-Content-Type-Options: nosniff aktif." || fail "Header X-Content-Type-Options: nosniff belum aktif."
    value="$(header_value "$headers" 'X-Frame-Options')"; [[ "${value^^}" = "SAMEORIGIN" || "${value^^}" = "DENY" ]] && pass "X-Frame-Options aktif." || fail "Header X-Frame-Options belum aktif."
    value="$(header_value "$headers" 'Referrer-Policy')"; [[ -n "$value" ]] && pass "Referrer-Policy aktif." || fail "Header Referrer-Policy belum aktif."
    value="$(header_value "$headers" 'Permissions-Policy')"; [[ -n "$value" ]] && pass "Permissions-Policy aktif." || fail "Header Permissions-Policy belum aktif."
    if [[ "$HTTP_PROBE_EFFECTIVE_MODE" != 'origin-http' && "$HTTP_PROBE_PUBLIC_BASE_URL" = https://* ]]; then
        value="$(header_value "$headers" 'Strict-Transport-Security')"; [[ -n "$value" ]] && pass "Strict-Transport-Security aktif pada HTTPS." || fail "Header Strict-Transport-Security belum aktif pada HTTPS."
    elif [[ "$HTTP_PROBE_EFFECTIVE_MODE" = 'origin-http' ]]; then
        value="$(header_value "$headers" 'Strict-Transport-Security')"
        if [[ -n "$value" ]]; then
            pass "Origin HTTP meneruskan Strict-Transport-Security untuk edge HTTPS."
        else
            warn "HSTS end-to-end belum dapat diverifikasi dari origin HTTP; aktifkan CHECK_EDGE_HTTP=true untuk observasi edge HTTPS."
        fi
    else
        warn "HSTS belum diperiksa karena PUBLIC_BASE_URL tidak memakai HTTPS."
    fi
}

check_nginx_configuration() {
    local config="$NGINX_CONFIG"
    if [[ -z "$config" && -f deploy/aapanel-nginx.conf ]]; then config='deploy/aapanel-nginx.conf'; fi
    if [[ ! -f "$config" ]]; then warn "Konfigurasi Nginx tidak tersedia untuk pemeriksaan statis."; return; fi
    grep -Eq 'root[[:space:]]+[^;]*/public;' "$config" && pass "Nginx document root mengarah ke public." || fail "Nginx document root harus mengarah ke public/."
    if grep -Fq 'location ~ /\.(?!well-known).* {' "$config" || grep -Fq 'location ~ ^/(\.user.ini|\.htaccess|\.git|\.env' "$config"; then
        pass "Nginx memiliki aturan deny file sensitif/dot-file."
    else
        fail "Nginx belum memiliki aturan deny file sensitif/dot-file."
    fi
    grep -Eq 'add_header[[:space:]]+X-Content-Type-Options[[:space:]]+"?nosniff"?' "$config" && pass "Template Nginx memiliki X-Content-Type-Options." || fail "Template Nginx belum memiliki X-Content-Type-Options."
    grep -Eq 'add_header[[:space:]]+X-Frame-Options[[:space:]]+"?(SAMEORIGIN|DENY)"?' "$config" && pass "Template Nginx memiliki X-Frame-Options." || fail "Template Nginx belum memiliki X-Frame-Options."
    grep -Eq 'add_header[[:space:]]+Referrer-Policy[[:space:]]+' "$config" && pass "Template Nginx memiliki Referrer-Policy." || fail "Template Nginx belum memiliki Referrer-Policy."
    grep -Eq 'add_header[[:space:]]+Permissions-Policy[[:space:]]+' "$config" && pass "Template Nginx memiliki Permissions-Policy." || fail "Template Nginx belum memiliki Permissions-Policy."
    if grep -Eq '^[[:space:]]*listen[[:space:]]+443' "$config"; then
        grep -Eq 'add_header[[:space:]]+Strict-Transport-Security[[:space:]]+.*always' "$config" && pass "Template Nginx HTTPS memiliki HSTS dengan always." || fail "Template Nginx HTTPS harus memiliki Strict-Transport-Security dengan always."
    fi
    if [[ "$CHECK_DOCKER" != "true" ]]; then
        grep -Fq 'location ~ ^/(app|apps)(?:/|$) {' "$config" && pass "Route proxy Reverb dibatasi pada /app dan /apps." || warn "Route proxy Reverb belum memakai batas path yang presisi."
        grep -Eq 'proxy_read_timeout[[:space:]]+(3[0-9]{2,}|[4-9][0-9]{2,}|[1-9][0-9]{3,})' "$config" && pass "Timeout baca WebSocket memadai." || warn "Timeout baca WebSocket kurang dari 300 detik."
    fi
    grep -Eq 'proxy_pass[[:space:]]+http://(127\.0\.0\.1|reverb:)' "$config" && pass "Proxy Reverb menuju backend internal." || warn "Proxy Reverb tidak dapat dipastikan menuju backend internal."
}

check_docker_configuration() {
    local compose_file='docker-compose.yml'
    if [[ "$CHECK_DOCKER" != "true" || ! -f "$compose_file" ]]; then return; fi
    grep -Eq '^[[:space:]]*privileged:[[:space:]]*true' "$compose_file" && fail "Docker Compose memakai privileged: true." || pass "Docker Compose tidak memakai privileged."
    grep -Eq '^USER[[:space:]]+www-data' docker/Dockerfile && pass "Container aplikasi berjalan sebagai www-data." || fail "Dockerfile aplikasi harus memakai user non-root."
    if awk '/^  db:$/ { in_db = 1; next } in_db && /^  [A-Za-z0-9_-]+:$/ { in_db = 0 } in_db && /^[[:space:]]+ports:/ { found = 1 } END { exit found ? 0 : 1 }' "$compose_file"; then fail "Service database mengekspos port host."; else pass "Service database tidak mengekspos port host."; fi
}

printf 'Security Gate SITA | profile=%s\n' "$PROFILE"
[[ -f .env ]] || { printf 'FAIL  .env tidak ditemukan.\n' >&2; exit 1; }
check_production_configuration
check_env_permission
check_compiled_assets
configure_http_probe
check_edge_http
check_public_exposure
check_security_headers
check_nginx_configuration
check_docker_configuration
printf '\nSecurity Gate selesai: %d gagal, %d peringatan.\n' "$failures" "$warnings"
(( failures == 0 ))
