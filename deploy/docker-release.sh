#!/usr/bin/env bash
set -Eeuo pipefail

# Checked Docker release flow. aaPanel uses deploy/aapanel-release.sh instead.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-release}"
PROFILE_FILE="${DOCKER_PROFILE_FILE:-${PROJECT_ROOT}/deploy/docker-profile.env}"
COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.deploy.yml)

case "$ACTION" in
    check|release) ;;
    *)
        printf 'Penggunaan: bash deploy/docker-release.sh [check|release]\n' >&2
        printf '  check   : verifikasi Docker tanpa membangun atau mengubah container\n' >&2
        printf '  release : preflight, build, deploy Compose, integration gate, dan security gate\n' >&2
        exit 2
        ;;
esac

if [ ! -f "$PROFILE_FILE" ]; then
    printf 'Profile Docker tidak ditemukan: %s\n' "$PROFILE_FILE" >&2
    printf 'Salin deploy/docker-profile.example.env menjadi deploy/docker-profile.env, lalu isi URL lab.\n' >&2
    exit 2
fi

# shellcheck disable=SC1090
source "$PROFILE_FILE"

HEALTHCHECK_URL="${HEALTHCHECK_URL:?HEALTHCHECK_URL wajib diisi pada profile Docker}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${HEALTHCHECK_URL%/up}}"
NGINX_CONFIG="${NGINX_CONFIG:-docker/nginx/default.conf}"
RUN_DEPENDENCY_AUDIT="${RUN_DEPENDENCY_AUDIT:-false}"
DEPENDENCY_AUDIT_MODE="${DEPENDENCY_AUDIT_MODE:-report}"
DEPENDENCY_AUDIT_THRESHOLD="${DEPENDENCY_AUDIT_THRESHOLD:-high}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    cyan='\033[36m'
    green='\033[32m'
    red='\033[31m'
    reset='\033[0m'
else
    cyan=''
    green=''
    red=''
    reset=''
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
LOG_DIR="${DOCKER_RELEASE_LOG_DIR:-${PROJECT_ROOT}/storage/logs/deployment}"
LOG_FILE="${LOG_DIR}/docker-${ACTION}-${RUN_ID}.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

banner() {
    printf '\n%b============================================================%b\n' "$cyan" "$reset"
    printf '%bSITA Docker release runner%b\n' "$cyan" "$reset"
    printf 'Mode: %s | Health: %s | Log: %s\n' "$ACTION" "$HEALTHCHECK_URL" "$LOG_FILE"
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

check_compose_configuration() {
    docker compose "${COMPOSE_FILES[@]}" config -q
}

security_preflight() {
    CHECK_HTTP=false \
        CHECK_DOCKER=true \
        NGINX_CONFIG="$NGINX_CONFIG" \
        bash scripts/security-gate.sh
}

integration_gate() {
    HEALTHCHECK_URL="$HEALTHCHECK_URL" \
        bash scripts/docker-integration-gate.sh
}

security_gate() {
    PUBLIC_BASE_URL="$PUBLIC_BASE_URL" \
        CHECK_DOCKER=true \
        NGINX_CONFIG="$NGINX_CONFIG" \
        bash scripts/security-gate.sh
}

deploy_application() {
    HEALTHCHECK_URL="$HEALTHCHECK_URL" \
        PUBLIC_BASE_URL="$PUBLIC_BASE_URL" \
        NGINX_CONFIG="$NGINX_CONFIG" \
        RUN_DEPENDENCY_AUDIT="$RUN_DEPENDENCY_AUDIT" \
        DEPENDENCY_AUDIT_MODE="$DEPENDENCY_AUDIT_MODE" \
        DEPENDENCY_AUDIT_THRESHOLD="$DEPENDENCY_AUDIT_THRESHOLD" \
        RUN_SECURITY_PREFLIGHT=false \
        RUN_INTEGRATION_GATE=true \
        RUN_SECURITY_GATE=true \
        bash scripts/deploy-via-compose.sh
}

cd "$PROJECT_ROOT"
banner

if [ "$ACTION" = 'check' ]; then
    phase '1/3' 'Validasi konfigurasi Docker Compose' check_compose_configuration
    phase '2/3' 'Integration gate Docker' integration_gate
    phase '3/3' 'Security gate Docker' security_gate
    printf '%bPEMERIKSAAN DOCKER DINYATAKAN SIAP%b\n' "$green" "$reset"
else
    phase '1/3' 'Validasi konfigurasi Docker Compose' check_compose_configuration
    phase '2/3' 'Security preflight Docker' security_preflight
    phase '3/3' 'Build dan deployment Docker Compose' deploy_application
    printf '%bRILIS DOCKER DINYATAKAN SIAP%b\n' "$green" "$reset"
fi

printf 'Log tersimpan di: %s\n' "$LOG_FILE"
