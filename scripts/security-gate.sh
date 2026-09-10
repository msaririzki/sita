#!/usr/bin/env bash

# Security gate ringan tanpa dependency baru untuk deployment SITA.
# Jalankan dari root proyek. Nilai .env tidak pernah dicetak.
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

PROFILE="${SECURITY_GATE_PROFILE:-production}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
NGINX_CONFIG="${NGINX_CONFIG:-}"
CHECK_HTTP="${CHECK_HTTP:-true}"
CHECK_DOCKER="${CHECK_DOCKER:-true}"

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
    local app_env app_debug reverb_origins
    app_env="$(env_value APP_ENV)"
    app_debug="$(env_value APP_DEBUG)"
    reverb_origins="$(env_value REVERB_ALLOWED_ORIGINS)"

    if [[ "$PROFILE" = "production" && "$app_env" != "production" ]]; then fail "APP_ENV harus production pada profile production."; else pass "APP_ENV sesuai profile $PROFILE."; fi
    if [[ "$PROFILE" = "production" && "$app_debug" != "false" ]]; then fail "APP_DEBUG harus false pada profile production."; else pass "APP_DEBUG aman untuk profile $PROFILE."; fi

    require_env_value APP_KEY
    require_env_value REVERB_APP_KEY
    require_env_value REVERB_APP_SECRET

    if [[ "$PROFILE" = "production" && ( -z "$reverb_origins" || "$reverb_origins" = *"*"* ) ]]; then
        fail "REVERB_ALLOWED_ORIGINS harus berisi origin eksplisit dan tidak boleh wildcard pada production."
    else
        pass "REVERB_ALLOWED_ORIGINS tidak memakai wildcard pada production."
    fi
}

check_env_permission() {
    local mode other group
    if ! command -v stat >/dev/null 2>&1; then warn "stat tidak tersedia; permission .env tidak diperiksa."; return; fi
    mode="$(stat -c '%a' .env 2>/dev/null || true)"
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

http_status() { curl -ksS -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || true; }

check_public_exposure() {
    local path status
    if [[ "$CHECK_HTTP" != "true" ]]; then warn "Pemeriksaan HTTP dinonaktifkan."; return; fi
    if [[ -z "$PUBLIC_BASE_URL" ]]; then fail "PUBLIC_BASE_URL wajib diisi agar endpoint publik dapat diperiksa."; return; fi
    PUBLIC_BASE_URL="${PUBLIC_BASE_URL%/}"
    for path in '/.env' '/.git/HEAD' '/composer.lock'; do
        status="$(http_status "${PUBLIC_BASE_URL}${path}")"
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
    if [[ "$CHECK_HTTP" != "true" || -z "$PUBLIC_BASE_URL" ]]; then return; fi
    headers="$(curl -ksS -D - -o /dev/null --max-time 10 "${PUBLIC_BASE_URL%/}/up" 2>/dev/null || true)"
    if [[ -z "$headers" ]]; then fail "Header keamanan tidak dapat diperiksa pada endpoint /up."; return; fi
    value="$(header_value "$headers" 'X-Content-Type-Options')"; [[ "${value,,}" = "nosniff" ]] && pass "X-Content-Type-Options: nosniff aktif." || fail "Header X-Content-Type-Options: nosniff belum aktif."
    value="$(header_value "$headers" 'X-Frame-Options')"; [[ "${value^^}" = "SAMEORIGIN" || "${value^^}" = "DENY" ]] && pass "X-Frame-Options aktif." || fail "Header X-Frame-Options belum aktif."
    value="$(header_value "$headers" 'Referrer-Policy')"; [[ -n "$value" ]] && pass "Referrer-Policy aktif." || fail "Header Referrer-Policy belum aktif."
    value="$(header_value "$headers" 'Permissions-Policy')"; [[ -n "$value" ]] && pass "Permissions-Policy aktif." || fail "Header Permissions-Policy belum aktif."
    if [[ "$PUBLIC_BASE_URL" = https://* ]]; then
        value="$(header_value "$headers" 'Strict-Transport-Security')"; [[ -n "$value" ]] && pass "Strict-Transport-Security aktif pada HTTPS." || fail "Header Strict-Transport-Security belum aktif pada HTTPS."
    else
        warn "HSTS belum diperiksa karena PUBLIC_BASE_URL tidak memakai HTTPS."
    fi
}

check_nginx_configuration() {
    local config="$NGINX_CONFIG"
    if [[ -z "$config" && -f deploy/aapanel-nginx.conf ]]; then config='deploy/aapanel-nginx.conf'; fi
    if [[ ! -f "$config" ]]; then warn "Konfigurasi Nginx tidak tersedia untuk pemeriksaan statis."; return; fi
    grep -Eq 'root[[:space:]]+[^;]*/public;' "$config" && pass "Nginx document root mengarah ke public." || fail "Nginx document root harus mengarah ke public/."
    grep -Fq 'location ~ /\.(?!well-known).* {' "$config" && pass "Nginx memiliki aturan deny dot-file." || fail "Nginx belum memiliki aturan deny dot-file."
    grep -Eq 'add_header[[:space:]]+X-Content-Type-Options[[:space:]]+"?nosniff"?' "$config" && pass "Template Nginx memiliki X-Content-Type-Options." || fail "Template Nginx belum memiliki X-Content-Type-Options."
    grep -Eq 'add_header[[:space:]]+X-Frame-Options[[:space:]]+"?(SAMEORIGIN|DENY)"?' "$config" && pass "Template Nginx memiliki X-Frame-Options." || fail "Template Nginx belum memiliki X-Frame-Options."
    grep -Eq 'add_header[[:space:]]+Referrer-Policy[[:space:]]+' "$config" && pass "Template Nginx memiliki Referrer-Policy." || fail "Template Nginx belum memiliki Referrer-Policy."
    grep -Eq 'add_header[[:space:]]+Permissions-Policy[[:space:]]+' "$config" && pass "Template Nginx memiliki Permissions-Policy." || fail "Template Nginx belum memiliki Permissions-Policy."
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
check_public_exposure
check_security_headers
check_nginx_configuration
check_docker_configuration
printf '\nSecurity Gate selesai: %d gagal, %d peringatan.\n' "$failures" "$warnings"
(( failures == 0 ))
