#!/usr/bin/env bash
set -Eeuo pipefail

# Single entry point for aaPanel operators. The implementation remains split
# into focused scripts; this runner makes the checked release flow observable.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-release}"
PROFILE_FILE="${AAPANEL_PROFILE_FILE:-${PROJECT_ROOT}/deploy/aapanel-profile.env}"
# A profile supplies safe defaults for ordinary console use. Keep explicit
# operator overrides so an approved non-interactive maintenance run can select
# the migration and first-vhost-root policy without editing the profile.
REQUESTED_MIGRATION_MODE="${MIGRATION_MODE-}"
REQUESTED_MANAGE_NGINX_ROOT="${MANAGE_NGINX_ROOT-}"

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
SITE_ROOT="${SITE_ROOT:-$APP_DIR}"
PHP_BIN="${PHP_BIN:-/www/server/php/84/bin/php}"
NODE_BIN="${NODE_BIN:-node}"
NPM_BIN="${NPM_BIN:-npm}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-php-fpm-84}"
PHP_FPM_RUNTIME_USER="${PHP_FPM_RUNTIME_USER:-www}"
PHP_FPM_RUNTIME_GROUP="${PHP_FPM_RUNTIME_GROUP:-$PHP_FPM_RUNTIME_USER}"
PHP_FPM_SOCKET="${PHP_FPM_SOCKET:-/tmp/php-cgi-84.sock}"
REVERB_INTERNAL_PORT="${REVERB_INTERNAL_PORT:-}"
NGINX_CONFIG="${NGINX_CONFIG:-/www/server/panel/vhost/nginx/${DOMAIN}.conf}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://${DOMAIN}/up}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${HEALTHCHECK_URL%/up}}"
HTTP_PROBE_MODE="${HTTP_PROBE_MODE:-auto}"
ORIGIN_PROBE_ADDRESS="${ORIGIN_PROBE_ADDRESS:-127.0.0.1}"
ORIGIN_PROBE_HTTP_PORT="${ORIGIN_PROBE_HTTP_PORT:-80}"
CHECK_EDGE_HTTP="${CHECK_EDGE_HTTP:-false}"
EDGE_ACCESS_POLICY="${EDGE_ACCESS_POLICY:-warn}"
RUN_MIGRATIONS="${RUN_MIGRATIONS:-false}"
MIGRATION_MODE="${REQUESTED_MIGRATION_MODE:-${MIGRATION_MODE:-prompt}}"
DB_BACKUP_DIR="${DB_BACKUP_DIR:-/var/backups/sita}"
DEPLOYMENT_STRATEGY="${DEPLOYMENT_STRATEGY:-in-place}"
RELEASE_ROOT="${RELEASE_ROOT:-${APP_DIR}/.sita-release}"
CURRENT_LINK="${CURRENT_LINK:-${RELEASE_ROOT}/current}"
MANAGE_NGINX_ROOT="${REQUESTED_MANAGE_NGINX_ROOT:-${MANAGE_NGINX_ROOT:-prompt}}"
MANAGE_NGINX_INTEGRATION="${MANAGE_NGINX_INTEGRATION:-true}"
RELEASE_KEEP="${RELEASE_KEEP:-3}"
RUN_DEPENDENCY_AUDIT="${RUN_DEPENDENCY_AUDIT:-false}"
DEPENDENCY_AUDIT_MODE="${DEPENDENCY_AUDIT_MODE:-report}"
DEPENDENCY_AUDIT_THRESHOLD="${DEPENDENCY_AUDIT_THRESHOLD:-high}"
INSTALL_SERVICES=false
INSTALL_MISSING_PHP_EXTENSIONS="${INSTALL_MISSING_PHP_EXTENSIONS:-true}"

# npm's executable uses /usr/bin/env node. When the profile points to the
# isolated SITA runtime, expose its bin directory to child build processes.
if [ -x "$NODE_BIN" ]; then
    export PATH="$(dirname "$NODE_BIN"):${PATH}"
fi

if [ "$ACTION" = 'bootstrap' ]; then
    INSTALL_SERVICES=true
fi

if [ "$APP_DIR" != "$PROJECT_ROOT" ]; then
    printf 'APP_DIR profile (%s) harus sama dengan lokasi runner (%s).\n' "$APP_DIR" "$PROJECT_ROOT" >&2
    exit 2
fi

profile_set_value() {
    local key="$1" value="$2" temporary_file

    temporary_file="$(mktemp "${PROFILE_FILE}.tmp.XXXXXX")"
    awk -v key="$key" -v value="$value" '
        index($0, key "=") == 1 { print key "=" value; seen=1; next }
        { print }
        END { if (!seen) print key "=" value }
    ' "$PROFILE_FILE" > "$temporary_file"
    mv "$temporary_file" "$PROFILE_FILE"
    chmod 600 "$PROFILE_FILE"
}

environment_value_at() {
    local environment_file="$1" key="$2"

    [ -f "$environment_file" ] || return
    grep -E "^${key}=" "$environment_file" | tail -n 1 | cut -d '=' -f 2- | sed -e 's/^"//' -e 's/"$//'
}

environment_value() {
    environment_value_at "$APP_DIR/.env" "$1"
}

environment_set_value_at() {
    local environment_file="$1" key="$2" value="$3" temporary_file

    [ -f "$environment_file" ] || return 0
    temporary_file="$(mktemp "$(dirname "$environment_file")/.env.tmp.XXXXXX")"
    awk -v key="$key" -v value="$value" '
        index($0, key "=") == 1 { print key "=\"" value "\""; seen=1; next }
        { print }
        END { if (!seen) print key "=\"" value "\"" }
    ' "$environment_file" > "$temporary_file"
    mv "$temporary_file" "$environment_file"
    chmod 640 "$environment_file"
    if ! chgrp "$PHP_FPM_RUNTIME_GROUP" "$environment_file" 2>/dev/null; then
        run_privileged chgrp "$PHP_FPM_RUNTIME_GROUP" "$environment_file"
    fi
}

environment_set_value() {
    local key="$1" value="$2" shared_environment

    environment_set_value_at "$APP_DIR/.env" "$key" "$value"
    shared_environment="${RELEASE_ROOT}/shared/.env"
    if [ "$DEPLOYMENT_STRATEGY" = 'atomic' ] && [ -f "$shared_environment" ] \
        && [ "$(readlink -f "$shared_environment")" != "$(readlink -f "$APP_DIR/.env")" ]; then
        environment_set_value_at "$shared_environment" "$key" "$value"
    fi
}

port_is_listening() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -ltnH "sport = :${port}" 2>/dev/null | grep -q .
        return
    fi

    timeout 1 bash -c "</dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1
}

port_is_owned_by_current_reverb_service() {
    local port="$1" service pid

    service="sita-$(printf '%s' "$DOMAIN" | tr -cs 'A-Za-z0-9' '-')-reverb.service"
    pid="$(run_privileged systemctl show "$service" -p MainPID --value 2>/dev/null || true)"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    run_privileged ss -ltnp "sport = :${port}" 2>/dev/null | grep -Fq "pid=${pid},"
}

find_available_reverb_port() {
    local seed offset candidate attempt

    seed="$(printf '%s' "$DOMAIN" | cksum | awk '{print $1}')"
    offset=$((seed % 1000))
    for ((attempt = 0; attempt < 1000; attempt++)); do
        candidate=$((18000 + ((offset + attempt) % 1000)))
        if ! port_is_listening "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

ensure_reverb_port_configuration() {
    local existing_port selected_port shared_environment

    if [ -n "$REVERB_INTERNAL_PORT" ]; then
        if [[ ! "$REVERB_INTERNAL_PORT" =~ ^[0-9]+$ ]] || [ "$REVERB_INTERNAL_PORT" -lt 1024 ] || [ "$REVERB_INTERNAL_PORT" -gt 65535 ]; then
            printf 'REVERB_INTERNAL_PORT pada profile harus berupa port nonprivileged 1024-65535.\n' >&2
            return 1
        fi
        shared_environment="${RELEASE_ROOT}/shared/.env"
        if [ "$(environment_value REVERB_INTERNAL_PORT)" != "$REVERB_INTERNAL_PORT" ] \
            || [ "$(environment_value REVERB_SERVER_PORT)" != "$REVERB_INTERNAL_PORT" ] \
            || { [ "$DEPLOYMENT_STRATEGY" = 'atomic' ] && [ -f "$shared_environment" ] \
                && { [ "$(environment_value_at "$shared_environment" REVERB_INTERNAL_PORT)" != "$REVERB_INTERNAL_PORT" ] \
                    || [ "$(environment_value_at "$shared_environment" REVERB_SERVER_PORT)" != "$REVERB_INTERNAL_PORT" ]; }; }; then
            environment_set_value REVERB_INTERNAL_PORT "$REVERB_INTERNAL_PORT"
            environment_set_value REVERB_SERVER_PORT "$REVERB_INTERNAL_PORT"
            printf '[OK] .env Reverb diselaraskan dengan profile: %s\n' "$REVERB_INTERNAL_PORT"
        fi
        return 0
    fi

    existing_port="$(environment_value REVERB_INTERNAL_PORT)"
    selected_port="$existing_port"
    if [[ ! "$selected_port" =~ ^[0-9]+$ ]] || [ "$selected_port" -lt 1024 ] || [ "$selected_port" -gt 65535 ]; then
        selected_port=8080
    fi

    if port_is_listening "$selected_port" && ! port_is_owned_by_current_reverb_service "$selected_port"; then
        selected_port="$(find_available_reverb_port)" || {
            printf 'Tidak ada port internal Reverb kosong dalam rentang 18000-18999.\n' >&2
            return 1
        }
    fi

    REVERB_INTERNAL_PORT="$selected_port"
    profile_set_value REVERB_INTERNAL_PORT "$REVERB_INTERNAL_PORT"
    environment_set_value REVERB_INTERNAL_PORT "$REVERB_INTERNAL_PORT"
    environment_set_value REVERB_SERVER_PORT "$REVERB_INTERNAL_PORT"
    printf '[OK] Port internal Reverb dikonfigurasi: %s\n' "$REVERB_INTERNAL_PORT"
}

case "$DEPLOYMENT_STRATEGY" in
    in-place|atomic) ;;
    *)
        printf 'DEPLOYMENT_STRATEGY harus in-place atau atomic.\n' >&2
        exit 2
        ;;
esac

active_app_dir() {
    if [ "$DEPLOYMENT_STRATEGY" = 'atomic' ] && [ -f "$CURRENT_LINK/artisan" ]; then
        printf '%s' "$CURRENT_LINK"
    else
        printf '%s' "$APP_DIR"
    fi
}

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

ensure_privileged_access() {
    if [ "$EUID" -eq 0 ]; then
        return
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        printf 'Akses root diperlukan. Jalankan console sebagai root atau pasang sudo untuk akun deploy.\n' >&2
        return 1
    fi

    if [ -t 0 ]; then
        if sudo -v; then
            return
        fi
    elif sudo -n true >/dev/null 2>&1; then
        return
    fi

    printf 'Akses sudo belum siap untuk akun %s. Jalankan sebagai root, atau berikan hak sudo sebelum menjalankan deployment.\n' "$(id -un)" >&2
    return 1
}

run_as_php_runtime_user() {
    if [ "$(id -un)" = "$PHP_FPM_RUNTIME_USER" ]; then
        "$@"
        return
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        printf 'sudo diperlukan untuk menjalankan Artisan sebagai user PHP-FPM %s.\n' "$PHP_FPM_RUNTIME_USER" >&2
        return 1
    fi

    sudo -u "$PHP_FPM_RUNTIME_USER" "$@"
}

sync_environment() {
    run_privileged env \
        DOMAIN="$DOMAIN" \
        APP_DIR="$(active_app_dir)" \
        SITE_ROOT="$SITE_ROOT" \
        PHP_BIN="$PHP_BIN" \
        NODE_BIN="$NODE_BIN" \
        NPM_BIN="$NPM_BIN" \
        PHP_FPM_RUNTIME_USER="$PHP_FPM_RUNTIME_USER" \
        PHP_FPM_SOCKET="$PHP_FPM_SOCKET" \
        REVERB_INTERNAL_PORT="$REVERB_INTERNAL_PORT" \
        NGINX_CONFIG="$NGINX_CONFIG" \
        CHECK_SERVICES=true \
        bash deploy/aapanel-sync.sh
}

doctor_environment() {
    DOMAIN="$DOMAIN" \
        APP_DIR="$(active_app_dir)" \
        PHP_BIN="$PHP_BIN" \
        NODE_BIN="$NODE_BIN" \
        NPM_BIN="$NPM_BIN" \
        PHP_FPM_SERVICE="$PHP_FPM_SERVICE" \
        REVERB_INTERNAL_PORT="$REVERB_INTERNAL_PORT" \
        HEALTHCHECK_URL="$HEALTHCHECK_URL" \
        CHECK_SERVICES=true \
        PUBLIC_BASE_URL="$PUBLIC_BASE_URL" \
        HTTP_PROBE_MODE="$HTTP_PROBE_MODE" \
        ORIGIN_PROBE_ADDRESS="$ORIGIN_PROBE_ADDRESS" \
        ORIGIN_PROBE_HTTP_PORT="$ORIGIN_PROBE_HTTP_PORT" \
        EDGE_ACCESS_POLICY="$EDGE_ACCESS_POLICY" \
        bash deploy/aapanel-doctor.sh
}

integration_gate() {
    run_privileged env \
        APP_DIR="$(active_app_dir)" \
        DOMAIN="$DOMAIN" \
        PHP_BIN="$PHP_BIN" \
        PHP_FPM_SERVICE="$PHP_FPM_SERVICE" \
        PHP_FPM_RUNTIME_USER="$PHP_FPM_RUNTIME_USER" \
        HEALTHCHECK_URL="$HEALTHCHECK_URL" \
        PUBLIC_BASE_URL="$PUBLIC_BASE_URL" \
        HTTP_PROBE_MODE="$HTTP_PROBE_MODE" \
        ORIGIN_PROBE_ADDRESS="$ORIGIN_PROBE_ADDRESS" \
        ORIGIN_PROBE_HTTP_PORT="$ORIGIN_PROBE_HTTP_PORT" \
        EDGE_ACCESS_POLICY="$EDGE_ACCESS_POLICY" \
        CHECK_EDGE_HTTP="$CHECK_EDGE_HTTP" \
        CHECK_SERVICES=true \
        CHECK_WEBSOCKET=true \
        bash deploy/aapanel-integration-gate.sh
}

runtime_integration_is_expected() {
    local slug service

    # A fresh aaPanel setup has no runtime service or active atomic release
    # yet, so Check remains a pre-bootstrap readiness check there. Once a
    # release or any SITA unit exists, a stopped Reverb/queue/scheduler is a
    # deployment failure and must not be downgraded to a warning.
    if [ -f "${CURRENT_LINK}/artisan" ]; then
        return 0
    fi

    slug="$(printf '%s' "$DOMAIN" | tr -cs 'A-Za-z0-9' '-')"
    for service in reverb queue schedule; do
        if run_privileged test -e "/etc/systemd/system/sita-${slug}-${service}.service" \
            || run_privileged test -e "/etc/systemd/system/sita-${slug}-${service}.timer"; then
            return 0
        fi
    done

    return 1
}

deploy_application() {
    if [ "$DEPLOYMENT_STRATEGY" = 'atomic' ]; then
        APP_DIR="$APP_DIR" \
            SITE_ROOT="$SITE_ROOT" \
            DOMAIN="$DOMAIN" \
            PHP_BIN="$PHP_BIN" \
            NPM_BIN="$NPM_BIN" \
            MIGRATION_MODE="$MIGRATION_MODE" \
            DB_BACKUP_DIR="$DB_BACKUP_DIR" \
            PHP_FPM_SERVICE="$PHP_FPM_SERVICE" \
            PHP_FPM_RUNTIME_USER="$PHP_FPM_RUNTIME_USER" \
            PHP_FPM_RUNTIME_GROUP="$PHP_FPM_RUNTIME_GROUP" \
            REVERB_INTERNAL_PORT="$REVERB_INTERNAL_PORT" \
            HEALTHCHECK_URL="$HEALTHCHECK_URL" \
            NGINX_CONFIG="$NGINX_CONFIG" \
            RELEASE_ROOT="$RELEASE_ROOT" \
            CURRENT_LINK="$CURRENT_LINK" \
            MANAGE_NGINX_ROOT="$MANAGE_NGINX_ROOT" \
            RELEASE_KEEP="$RELEASE_KEEP" \
            HTTP_PROBE_MODE="$HTTP_PROBE_MODE" \
            ORIGIN_PROBE_ADDRESS="$ORIGIN_PROBE_ADDRESS" \
            ORIGIN_PROBE_HTTP_PORT="$ORIGIN_PROBE_HTTP_PORT" \
            CHECK_EDGE_HTTP="$CHECK_EDGE_HTTP" \
            EDGE_ACCESS_POLICY="$EDGE_ACCESS_POLICY" \
            bash deploy/aapanel-atomic-release.sh
        return
    fi

    DOMAIN="$DOMAIN" \
        PHP_BIN="$PHP_BIN" \
        NODE_BIN="$NODE_BIN" \
        NPM_BIN="$NPM_BIN" \
        PHP_FPM_SERVICE="$PHP_FPM_SERVICE" \
        PHP_FPM_RUNTIME_USER="$PHP_FPM_RUNTIME_USER" \
            PHP_FPM_RUNTIME_GROUP="$PHP_FPM_RUNTIME_GROUP" \
            REVERB_SERVER_PORT="$REVERB_INTERNAL_PORT" \
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

provision_initial_super_admin() {
    local app_dir

    app_dir="$(active_app_dir)"
    if [ ! -t 0 ]; then
        # The Artisan command safely skips provisioning when a restored or
        # previously bootstrapped database already has a user. On an empty
        # database it rejects --no-interaction and tells the operator to use
        # an interactive terminal, which keeps first-account credentials out
        # of automation arguments and logs.
        run_as_php_runtime_user "$PHP_BIN" "$app_dir/artisan" sita:provision-initial-super-admin --no-interaction
        return
    fi

    run_as_php_runtime_user "$PHP_BIN" "$app_dir/artisan" sita:provision-initial-super-admin
}

security_gate() {
    run_privileged env \
        APP_DIR="$(active_app_dir)" \
        PUBLIC_BASE_URL="$PUBLIC_BASE_URL" \
        HTTP_PROBE_MODE="$HTTP_PROBE_MODE" \
        ORIGIN_PROBE_ADDRESS="$ORIGIN_PROBE_ADDRESS" \
        ORIGIN_PROBE_HTTP_PORT="$ORIGIN_PROBE_HTTP_PORT" \
        CHECK_EDGE_HTTP="$CHECK_EDGE_HTTP" \
        NGINX_CONFIG="$NGINX_CONFIG" \
        CHECK_DOCKER=false \
        bash scripts/security-gate.sh --mode=warn --environment=aapanel
}

prepare_php_extensions() {
    if [ "$INSTALL_MISSING_PHP_EXTENSIONS" != 'true' ]; then
        printf 'Pemasangan extension PHP otomatis dinonaktifkan oleh profile.\n'
        return
    fi

    DOMAIN="$DOMAIN" \
        PHP_BIN="$PHP_BIN" \
        PHP_FPM_SERVICE="$PHP_FPM_SERVICE" \
        bash "$PROJECT_ROOT/deploy/aapanel-php-extensions.sh"
}

prepare_runtime_directories() {
    local directory

    if ! getent group "$PHP_FPM_RUNTIME_GROUP" >/dev/null 2>&1; then
        printf 'Group runtime PHP-FPM tidak ditemukan: %s\n' "$PHP_FPM_RUNTIME_GROUP" >&2
        return 1
    fi

    for directory in \
        "$PROJECT_ROOT/storage/app/public" \
        "$PROJECT_ROOT/storage/app/private" \
        "$PROJECT_ROOT/storage/framework/cache/data" \
        "$PROJECT_ROOT/storage/framework/sessions" \
        "$PROJECT_ROOT/storage/framework/views" \
        "$PROJECT_ROOT/storage/logs" \
        "$PROJECT_ROOT/bootstrap/cache"; do
        run_privileged install -d -m 2770 -g "$PHP_FPM_RUNTIME_GROUP" "$directory"
    done

    run_privileged chgrp -R "$PHP_FPM_RUNTIME_GROUP" "$PROJECT_ROOT/storage" "$PROJECT_ROOT/bootstrap/cache"
    run_privileged chmod -R ug+rwX "$PROJECT_ROOT/storage" "$PROJECT_ROOT/bootstrap/cache"
    run_privileged chgrp "$PHP_FPM_RUNTIME_GROUP" "$PROJECT_ROOT/.env"
    run_privileged chmod 640 "$PROJECT_ROOT/.env"
    printf 'Direktori runtime SITA siap ditulis oleh user PHP-FPM %s.\n' "$PHP_FPM_RUNTIME_USER"
}

prepare_nginx_integration() {
    DOMAIN="$DOMAIN" \
        NGINX_CONFIG="$NGINX_CONFIG" \
        REVERB_INTERNAL_PORT="$REVERB_INTERNAL_PORT" \
        MANAGE_NGINX_INTEGRATION="$MANAGE_NGINX_INTEGRATION" \
        bash "$PROJECT_ROOT/deploy/aapanel-nginx-integration.sh"
}

banner
ensure_privileged_access
ensure_reverb_port_configuration
if [ "$ACTION" = 'release' ] && [ "$DEPLOYMENT_STRATEGY" = 'atomic' ]; then
    phase '1/4' 'Pasang integrasi Laravel dan Reverb pada vhost aaPanel' prepare_nginx_integration
    phase '2/4' 'Sinkronisasi GUI aaPanel dan runtime' sync_environment
    phase '3/4' 'Precheck runtime dan aplikasi' doctor_environment
    phase '4/4' 'Atomic release, gate, dan rollback otomatis' deploy_application
    printf '%bRILIS DINYATAKAN SIAP%b\n' "$green" "$reset"
    printf 'Log tersimpan di: %s\n' "$LOG_FILE"
    exit 0
fi

if [ "$ACTION" = 'bootstrap' ] || [ "$ACTION" = 'release' ]; then
    if [ "$ACTION" = 'bootstrap' ]; then
        phase '1/9' 'Siapkan extension PHP yang diperlukan' prepare_php_extensions
        phase '2/9' 'Pasang integrasi Laravel dan Reverb pada vhost aaPanel' prepare_nginx_integration
        phase '3/9' 'Siapkan direktori runtime SITA' prepare_runtime_directories
        phase '4/9' 'Sinkronisasi GUI aaPanel dan runtime' sync_environment
        phase '5/9' 'Precheck runtime dan aplikasi' doctor_environment
    else
        phase '1/6' 'Pasang integrasi Laravel dan Reverb pada vhost aaPanel' prepare_nginx_integration
        phase '2/6' 'Sinkronisasi GUI aaPanel dan runtime' sync_environment
        phase '3/6' 'Precheck runtime dan aplikasi' doctor_environment
    fi
    if [ "$ACTION" = 'bootstrap' ]; then
        phase '6/9' 'Deployment awal dan pemasangan service runtime' deploy_application
        phase '7/9' 'Buat akun Super Admin pertama bila database masih kosong' provision_initial_super_admin
    else
        phase '4/6' 'Deployment aplikasi' deploy_application
    fi
    if [ "$ACTION" = 'bootstrap' ]; then
        phase '8/9' 'Validasi sinkronisasi pascadeploy' sync_environment
        phase '9/9' 'Security gate pascadeploy' security_gate
    else
        phase '5/6' 'Validasi sinkronisasi pascadeploy' sync_environment
        phase '6/6' 'Security gate pascadeploy' security_gate
    fi
    if [ "$ACTION" = 'bootstrap' ]; then
        printf '%bDEPLOY AWAL DINYATAKAN SIAP%b\n' "$green" "$reset"
    else
        printf '%bRILIS DINYATAKAN SIAP%b\n' "$green" "$reset"
    fi
else
    phase '1/3' 'Sinkronisasi GUI aaPanel dan runtime' sync_environment
    phase '2/3' 'Precheck runtime dan aplikasi' doctor_environment
    if runtime_integration_is_expected; then
        phase '3/3' 'Validasi integrasi runtime dan chat realtime' integration_gate
    else
        printf 'Runtime service belum dipasang; validasi integrasi akan dijalankan setelah Bootstrap.\n'
    fi
    printf '%bPEMERIKSAAN DINYATAKAN SIAP%b\n' "$green" "$reset"
fi

printf 'Log tersimpan di: %s\n' "$LOG_FILE"
