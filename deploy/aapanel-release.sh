#!/usr/bin/env bash
set -Eeuo pipefail

# Single entry point for aaPanel operators. The implementation remains split
# into focused scripts; this runner makes the checked release flow observable.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-release}"
PROFILE_FILE="${AAPANEL_PROFILE_FILE:-${PROJECT_ROOT}/deploy/aapanel-profile.env}"

case "$ACTION" in
    bootstrap|check|release) ;;
    *)
        printf 'Penggunaan: bash deploy/aapanel-release.sh [bootstrap|check|release]\n' >&2
        printf '  bootstrap : siapkan server baru: deploy awal dan aktifkan service runtime\n' >&2
        printf '  check   : verifikasi aaPanel tanpa mengubah aplikasi\n' >&2
        printf '  release : check, deploy, integration gate, dan security gate\n' >&2
        exit 2
        ;;
esac

if [ ! -f "$PROFILE_FILE" ]; then
    printf 'Profile tidak ditemukan: %s\n' "$PROFILE_FILE" >&2
    printf 'Salin deploy/aapanel-profile.example.env menjadi deploy/aapanel-profile.env, lalu isi domain dan path server.\n' >&2
    exit 2
fi

# shellcheck disable=SC1090
source "$PROFILE_FILE"

DOMAIN="${DOMAIN:?DOMAIN wajib diisi pada profile}"
APP_DIR="${APP_DIR:-$PROJECT_ROOT}"
PHP_BIN="${PHP_BIN:-/www/server/php/84/bin/php}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-php-fpm-84}"
PHP_FPM_RUNTIME_USER="${PHP_FPM_RUNTIME_USER:-www}"
PHP_FPM_RUNTIME_GROUP="${PHP_FPM_RUNTIME_GROUP:-$PHP_FPM_RUNTIME_USER}"
PHP_FPM_SOCKET="${PHP_FPM_SOCKET:-/tmp/php-cgi-84.sock}"
NGINX_CONFIG="${NGINX_CONFIG:-/www/server/panel/vhost/nginx/${DOMAIN}.conf}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://${DOMAIN}/up}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${HEALTHCHECK_URL%/up}}"
RUN_MIGRATIONS="${RUN_MIGRATIONS:-false}"
MIGRATION_MODE="${MIGRATION_MODE:-prompt}"
DB_BACKUP_DIR="${DB_BACKUP_DIR:-/var/backups/sita}"
RUN_DEPENDENCY_AUDIT="${RUN_DEPENDENCY_AUDIT:-false}"
DEPENDENCY_AUDIT_MODE="${DEPENDENCY_AUDIT_MODE:-report}"
DEPENDENCY_AUDIT_THRESHOLD="${DEPENDENCY_AUDIT_THRESHOLD:-high}"
INSTALL_SERVICES=false

if [ "$ACTION" = 'bootstrap' ]; then
    INSTALL_SERVICES=true
fi

if [ "$APP_DIR" != "$PROJECT_ROOT" ]; then
    printf 'APP_DIR profile (%s) harus sama dengan lokasi runner (%s).\n' "$APP_DIR" "$PROJECT_ROOT" >&2
    exit 2
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    cyan='\033[36m'
    green='\033[32m'
    red='\033[31m'
    yellow='\033[33m'
    reset='\033[0m'
else
    cyan=''
    green=''
    red=''
    yellow=''
    reset=''
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${AAPANEL_RELEASE_LOG_DIR:-${PROJECT_ROOT}/storage/logs/deployment}"
LOG_FILE="${LOG_DIR}/aapanel-${ACTION}-${RUN_ID}.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

banner() {
    printf '\n%b============================================================%b\n' "$cyan" "$reset"
    printf '%bSITA aaPanel release runner%b\n' "$cyan" "$reset"
    printf 'Mode: %s | Domain: %s | Log: %s\n' "$ACTION" "$DOMAIN" "$LOG_FILE"
    printf '%b============================================================%b\n\n' "$cyan" "$reset"
}

phase() {
    local number="$1" label="$2"
    shift 2

    printf '%b[%s] %s%b\n' "$cyan" "$number" "$label" "$reset"
    if "$@"; then
        printf '%b[SELESAI] %s%b\n\n' "$green" "$label" "$reset"
    else
        printf '%b[GAGAL] %s. Lihat log: %s%b\n' "$red" "$label" "$LOG_FILE" "$reset" >&2
        exit 1
    fi
}

run_privileged() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

sync_environment() {
    run_privileged env \
        DOMAIN="$DOMAIN" \
        APP_DIR="$APP_DIR" \
        PHP_BIN="$PHP_BIN" \
        PHP_FPM_RUNTIME_USER="$PHP_FPM_RUNTIME_USER" \
        PHP_FPM_SOCKET="$PHP_FPM_SOCKET" \
        NGINX_CONFIG="$NGINX_CONFIG" \
        CHECK_SERVICES=true \
        bash deploy/aapanel-sync.sh
}

doctor_environment() {
    DOMAIN="$DOMAIN" \
        PHP_BIN="$PHP_BIN" \
        PHP_FPM_SERVICE="$PHP_FPM_SERVICE" \
        HEALTHCHECK_URL="$HEALTHCHECK_URL" \
        CHECK_SERVICES=true \
        bash deploy/aapanel-doctor.sh
}

deploy_application() {
    DOMAIN="$DOMAIN" \
        PHP_BIN="$PHP_BIN" \
        PHP_FPM_SERVICE="$PHP_FPM_SERVICE" \
        PHP_FPM_RUNTIME_USER="$PHP_FPM_RUNTIME_USER" \
        PHP_FPM_RUNTIME_GROUP="$PHP_FPM_RUNTIME_GROUP" \
        HEALTHCHECK_URL="$HEALTHCHECK_URL" \
        RUN_MIGRATIONS="$RUN_MIGRATIONS" \
        MIGRATION_MODE="$MIGRATION_MODE" \
        DB_BACKUP_DIR="$DB_BACKUP_DIR" \
        RUN_DEPENDENCY_AUDIT="$RUN_DEPENDENCY_AUDIT" \
        DEPENDENCY_AUDIT_MODE="$DEPENDENCY_AUDIT_MODE" \
        DEPENDENCY_AUDIT_THRESHOLD="$DEPENDENCY_AUDIT_THRESHOLD" \
        INSTALL_SERVICES="$INSTALL_SERVICES" \
        RUN_INTEGRATION_GATE=true \
        CHECK_SERVICES=true \
        RUN_SECURITY_PREFLIGHT=false \
        RUN_SECURITY_GATE=false \
        CHECK_DOCKER=false \
        bash deploy/aapanel-deploy.sh
}

security_gate() {
    run_privileged env \
        PUBLIC_BASE_URL="$PUBLIC_BASE_URL" \
        NGINX_CONFIG="$NGINX_CONFIG" \
        CHECK_DOCKER=false \
        bash scripts/security-gate.sh --mode=warn --environment=aapanel
}

banner
if [ "$ACTION" = 'bootstrap' ] || [ "$ACTION" = 'release' ]; then
    phase '1/5' 'Sinkronisasi GUI aaPanel dan runtime' sync_environment
    phase '2/5' 'Precheck runtime dan aplikasi' doctor_environment
    if [ "$ACTION" = 'bootstrap' ]; then
        phase '3/5' 'Deployment awal dan pemasangan service runtime' deploy_application
    else
        phase '3/5' 'Deployment aplikasi' deploy_application
    fi
    phase '4/5' 'Validasi sinkronisasi pascadeploy' sync_environment
    phase '5/5' 'Security gate pascadeploy' security_gate
    if [ "$ACTION" = 'bootstrap' ]; then
        printf '%bDEPLOY AWAL DINYATAKAN SIAP%b\n' "$green" "$reset"
    else
        printf '%bRILIS DINYATAKAN SIAP%b\n' "$green" "$reset"
    fi
else
    phase '1/2' 'Sinkronisasi GUI aaPanel dan runtime' sync_environment
    phase '2/2' 'Precheck runtime dan aplikasi' doctor_environment
    printf '%bPEMERIKSAAN DINYATAKAN SIAP%b\n' "$green" "$reset"
fi

printf 'Log tersimpan di: %s\n' "$LOG_FILE"
