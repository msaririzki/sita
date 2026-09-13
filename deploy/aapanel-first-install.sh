#!/usr/bin/env bash
set -Eeuo pipefail

# Standalone first-install wizard for a fresh aaPanel SITA website. It is meant
# to be downloaded once, then the regular repository console handles all later
# bootstrap, check, release, migration, and rollback operations.

REPOSITORY_URL="${SITA_REPOSITORY_URL:-https://github.com/msaririzki/sita.git}"
DEFAULT_BRANCH="${SITA_BRANCH:-codex/dependency-audit-p1}"
PHP_BIN="${PHP_BIN:-/www/server/php/84/bin/php}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-php-fpm-84}"
PHP_RUNTIME_GROUP="${PHP_FPM_RUNTIME_GROUP:-www}"

if [ ! -t 0 ]; then
    printf 'Wizard instalasi awal harus dijalankan dari terminal interaktif.\n' >&2
    exit 2
fi

blue='\033[38;5;39m'
cyan='\033[38;5;51m'
green='\033[38;5;48m'
yellow='\033[38;5;220m'
red='\033[38;5;203m'
reset='\033[0m'

step() { printf '\n%b[%s]%b %s\n' "$cyan" "$1" "$reset" "$2"; }
ok() { printf '%b[OK]%b %s\n' "$green" "$reset" "$*"; }
fail() { printf '%b[FAIL]%b %s\n' "$red" "$reset" "$*" >&2; }
warn() { printf '%b[WARN]%b %s\n' "$yellow" "$reset" "$*"; }

require_command() {
    command -v "$1" >/dev/null 2>&1 || { fail "Command wajib tidak tersedia: $1"; exit 1; }
}

ask() {
    local prompt="$1" default_value="$2" value
    read -r -p "${prompt} [${default_value}]: " value
    printf '%s' "${value:-$default_value}"
}

ask_secret() {
    local prompt="$1" value
    while true; do
        read -r -s -p "$prompt: " value
        printf '\n'
        if [ -n "$value" ]; then
            printf '%s' "$value"
            return
        fi
        warn 'Nilai tidak boleh kosong.'
    done
}

dotenv_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//\$/\\\$}"
    printf '"%s"' "$value"
}

set_env_value() {
    local key="$1" value="$2" encoded temp
    encoded="$(dotenv_quote "$value")"
    temp="$(mktemp "${APP_DIR}/.env.tmp.XXXXXX")"
    awk -v key="$key" -v value="$encoded" '
        index($0, key "=") == 1 { print key "=" value; seen=1; next }
        { print }
        END { if (!seen) print key "=" value }
    ' "$APP_DIR/.env" > "$temp"
    mv "$temp" "$APP_DIR/.env"
}

write_profile() {
    cat > "$APP_DIR/deploy/aapanel-profile.env" <<EOF
# Dibuat oleh SITA First Install Wizard. Tidak berisi secret.
DOMAIN=${DOMAIN}
APP_DIR=${APP_DIR}
PHP_BIN=${PHP_BIN}
PHP_FPM_SERVICE=${PHP_FPM_SERVICE}
PHP_FPM_RUNTIME_USER=www
PHP_FPM_RUNTIME_GROUP=${PHP_RUNTIME_GROUP}
PHP_FPM_SOCKET=/tmp/php-cgi-84.sock
NGINX_CONFIG=/www/server/panel/vhost/nginx/${DOMAIN}.conf
HEALTHCHECK_URL=https://${DOMAIN}/up
PUBLIC_BASE_URL=https://${DOMAIN}
HTTP_PROBE_MODE=auto
ORIGIN_PROBE_ADDRESS=127.0.0.1
ORIGIN_PROBE_HTTP_PORT=80
CHECK_EDGE_HTTP=true
MIGRATION_MODE=prompt
DB_BACKUP_DIR=/var/backups/sita
RUN_MIGRATIONS=false
DEPLOYMENT_STRATEGY=atomic
RELEASE_ROOT=${APP_DIR}/.sita-release
CURRENT_LINK=${APP_DIR}/.sita-release/current
MANAGE_NGINX_ROOT=prompt
RELEASE_KEEP=3
RUN_DEPENDENCY_AUDIT=false
DEPENDENCY_AUDIT_MODE=report
DEPENDENCY_AUDIT_THRESHOLD=high
EOF
    chmod 600 "$APP_DIR/deploy/aapanel-profile.env"
}

printf '\n%b SITA FIRST INSTALL WIZARD %b\n' "$blue" "$reset"
printf 'Menyiapkan source, .env, dan profile aaPanel tanpa menampilkan secret.\n'
printf 'Prasyarat GUI: Nginx, PHP 8.4, website, dan database/user SITA sudah dibuat.\n'

require_command git
require_command openssl
require_command sudo
require_command "$PHP_BIN"

step '1/5' 'Pilih lokasi dan branch source'
DOMAIN="$(ask 'Domain SITA' "${SITA_DOMAIN:-sita-aapanel.ikydev.com}")"
if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
    fail 'Domain tidak valid.'
    exit 2
fi
APP_DIR="$(ask 'Path source SITA' "${SITA_APP_DIR:-/www/wwwroot/${DOMAIN}}")"
if [[ ! "$APP_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || [[ "$APP_DIR" == '/' ]]; then
    fail 'Path source harus absolut, bukan root filesystem, dan hanya boleh berisi huruf, angka, titik, garis bawah, garis miring, atau tanda minus.'
    exit 2
fi
BRANCH="$(ask 'Branch Git' "$DEFAULT_BRANCH")"

if [ -d "$APP_DIR/.git" ]; then
    fail "Repository sudah ada di $APP_DIR. Gunakan console reguler: bash deploy/sita.sh"
    exit 1
fi

if [ -e "$APP_DIR" ]; then
    warn "Direktori aaPanel sudah ada: $APP_DIR"
    find "$APP_DIR" -maxdepth 1 -mindepth 1 -printf '  %f\n' 2>/dev/null | head -n 20 || true
    read -r -p 'Lanjutkan dan pertahankan file lokal aaPanel tersebut? [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) printf 'Instalasi dibatalkan tanpa perubahan.\n'; exit 0 ;;
    esac
else
    sudo install -d -m 750 -o "$USER" -g "$PHP_RUNTIME_GROUP" "$APP_DIR"
fi
sudo chown "$USER":"$PHP_RUNTIME_GROUP" "$APP_DIR"
sudo chmod 750 "$APP_DIR"

step '2/5' 'Ambil source SITA tanpa menghapus file aaPanel'
cd "$APP_DIR"
git init
git remote add origin "$REPOSITORY_URL"
git fetch --depth=1 origin "$BRANCH"
git checkout -b "$BRANCH" FETCH_HEAD
ok "Source aktif pada branch $BRANCH"

step '3/5' 'Isi konfigurasi aplikasi secara aman'
if [ -f .env ]; then
    read -r -p '.env sudah ada. Tulis ulang dengan konfigurasi wizard? [y/N]: ' answer
    case "$answer" in
        y|Y|yes|YES)
            cp .env ".env.before-wizard.$(date -u +%Y%m%dT%H%M%SZ)"
            ;;
        *)
            ok '.env lama dipertahankan.'
            SKIP_ENV=true
            ;;
    esac
fi

if [ "${SKIP_ENV:-false}" != true ]; then
    cp .env.example .env
    DB_HOST="$(ask 'Host database' '127.0.0.1')"
    DB_PORT="$(ask 'Port database' '3306')"
    DB_DATABASE="$(ask 'Nama database' 'sita_aapanel')"
    DB_USERNAME="$(ask 'Username database' 'sita_aapanel')"
    DB_PASSWORD="$(ask_secret 'Password database (tidak ditampilkan)')"

    set_env_value APP_NAME SITA
    set_env_value APP_ENV production
    set_env_value APP_DEBUG false
    set_env_value APP_URL "https://${DOMAIN}"
    set_env_value APP_TIMEZONE Asia/Makassar
    set_env_value APP_KEY "base64:$(openssl rand -base64 32)"
    set_env_value LOG_LEVEL info
    set_env_value DB_CONNECTION mysql
    set_env_value DB_HOST "$DB_HOST"
    set_env_value DB_PORT "$DB_PORT"
    set_env_value DB_DATABASE "$DB_DATABASE"
    set_env_value DB_USERNAME "$DB_USERNAME"
    set_env_value DB_PASSWORD "$DB_PASSWORD"
    set_env_value SESSION_DRIVER database
    set_env_value SESSION_SECURE_COOKIE true
    set_env_value SESSION_SAME_SITE lax
    set_env_value CACHE_STORE database
    set_env_value QUEUE_CONNECTION database
    set_env_value BROADCAST_CONNECTION reverb
    set_env_value REVERB_APP_ID "sita-${DOMAIN//./-}"
    set_env_value REVERB_APP_KEY "$(openssl rand -hex 16)"
    set_env_value REVERB_APP_SECRET "$(openssl rand -hex 32)"
    set_env_value REVERB_HOST "$DOMAIN"
    set_env_value REVERB_PORT 443
    set_env_value REVERB_SCHEME https
    set_env_value REVERB_INTERNAL_HOST 127.0.0.1
    set_env_value REVERB_INTERNAL_PORT 8080
    set_env_value REVERB_INTERNAL_SCHEME http
    set_env_value REVERB_SERVER_HOST 127.0.0.1
    set_env_value REVERB_SERVER_PORT 8080
    set_env_value REVERB_ALLOWED_ORIGINS "$DOMAIN"
    set_env_value FRONTEND_REVERB_HOST "$DOMAIN"
    set_env_value VITE_REVERB_HOST "$DOMAIN"
    set_env_value VITE_REVERB_PORT 443
    set_env_value VITE_REVERB_SCHEME https
    set_env_value MAIL_MAILER log
    chmod 640 .env
    chgrp "$PHP_RUNTIME_GROUP" .env
    ok '.env dibuat; APP_KEY dan key Reverb dibuat otomatis tanpa ditampilkan.'
fi

step '4/5' 'Buat profile operasional aaPanel'
write_profile
ok 'Profile dibuat tanpa password atau secret.'

step '5/5' 'Tentukan tindakan berikutnya'
printf '\nSource : %s\nProfile: %s\n' "$APP_DIR" "$APP_DIR/deploy/aapanel-profile.env"
printf 'Profile menyimpan domain, path, PHP-FPM, vhost, healthcheck, backup, dan mode atomic.\n'
printf 'Rahasia hanya berada pada .env dengan mode 640.\n\n'
read -r -p 'Jalankan Bootstrap sekarang? [y/N]: ' answer
case "$answer" in
    y|Y|yes|YES) exec bash "$APP_DIR/deploy/sita.sh" aapanel bootstrap ;;
    *)
        printf '\nSiap. Setelah Node.js tersedia, jalankan:\n'
        printf '  cd %s\n  bash deploy/sita.sh aapanel check\n  bash deploy/sita.sh aapanel bootstrap\n' "$APP_DIR"
        ;;
esac
