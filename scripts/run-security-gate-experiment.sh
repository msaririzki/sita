#!/usr/bin/env bash

# Menjalankan eksperimen Security Gate yang aman dan dapat diulang.
# Hanya untuk VM laboratorium. Tidak mengubah konfigurasi Nginx aktif.
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

if [[ "${SECURITY_EXPERIMENT_SCOPE:-}" != "lab" || "${ALLOW_SECURITY_EXPERIMENTS:-false}" != "true" ]]; then
    printf 'Eksperimen diblokir. Jalankan hanya pada VM lab dengan SECURITY_EXPERIMENT_SCOPE=lab dan ALLOW_SECURITY_EXPERIMENTS=true.\n' >&2
    exit 1
fi

[[ -f .env ]] || { printf '.env tidak ditemukan.\n' >&2; exit 1; }

PUBLIC_BASE_URL="${PUBLIC_BASE_URL:?PUBLIC_BASE_URL wajib diisi untuk baseline.}"
NGINX_CONFIG="${NGINX_CONFIG:-deploy/aapanel-nginx.conf}"
CHECK_DOCKER="${CHECK_DOCKER:-true}"
EXPERIMENT_RUNS="${SECURITY_EXPERIMENT_RUNS:-1}"
REPORT_DIR="${SECURITY_EXPERIMENT_REPORT_DIR:-storage/app/security-gate-experiments}"
mkdir -p "$REPORT_DIR"

if [[ ! "$EXPERIMENT_RUNS" =~ ^[1-9][0-9]*$ ]]; then
    printf 'SECURITY_EXPERIMENT_RUNS harus berupa bilangan bulat positif.\n' >&2
    exit 1
fi

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_FILE="${REPORT_DIR%/}/security-gate-${timestamp}.csv"
LOG_DIR="${REPORT_DIR%/}/security-gate-${timestamp}-logs"
mkdir -p "$LOG_DIR"
chmod 700 "$LOG_DIR"

env_backup="$(mktemp .env.security-gate-experiment.XXXXXX)"
nginx_fixture=""
cp -p .env "$env_backup"

restore_env() {
    if [[ -f "$env_backup" ]]; then
        cp -p "$env_backup" .env
        rm -f "$env_backup"
    fi
}

cleanup() {
    restore_env
    if [[ -n "$nginx_fixture" ]]; then
        rm -f "$nginx_fixture"
    fi
}
trap cleanup EXIT

printf 'timestamp_utc,run,scenario,expected,gate_exit,detection,duration_ms\n' > "$REPORT_FILE"
unexpected=0

set_env_value() {
    local key="$1" value="$2"
    if grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        printf '\n%s=%s\n' "$key" "$value" >> .env
    fi
}

run_case() {
    local scenario="$1" expected="$2" needle="$3"
    shift 3

    local started finished duration exit_code detected log_file
    log_file="${LOG_DIR}/run-${run_index}-${scenario}.log"
    started="$(date +%s%3N)"
    if env "$@" bash scripts/security-gate.sh > "$log_file" 2>&1; then
        exit_code=0
    else
        exit_code=$?
    fi
    finished="$(date +%s%3N)"
    duration=$((finished - started))
    detected=false

    if [[ "$expected" = "pass" && "$exit_code" -eq 0 ]]; then
        detected=true
    elif [[ "$expected" = "fail" && "$exit_code" -ne 0 ]] && grep -Fq "$needle" "$log_file"; then
        detected=true
    fi

    printf '%s,%s,%s,%s,%s,%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$run_index" "$scenario" "$expected" "$exit_code" "$detected" "$duration" >> "$REPORT_FILE"
    printf 'run=%s %-24s expected=%-4s detected=%-5s duration_ms=%s\n' "$run_index" "$scenario" "$expected" "$detected" "$duration"

    if [[ "$detected" != "true" ]]; then
        unexpected=$((unexpected + 1))
    fi
}

for run_index in $(seq 1 "$EXPERIMENT_RUNS"); do
    run_case baseline_safe pass '' \
        SECURITY_GATE_PROFILE=production \
        PUBLIC_BASE_URL="$PUBLIC_BASE_URL" \
        NGINX_CONFIG="$NGINX_CONFIG" \
        CHECK_DOCKER="$CHECK_DOCKER"

    set_env_value REVERB_ALLOWED_ORIGINS '*'
    run_case reverb_origin_wildcard fail 'REVERB_ALLOWED_ORIGINS harus berisi hostname eksplisit' \
        SECURITY_GATE_PROFILE=production CHECK_HTTP=false CHECK_DOCKER="$CHECK_DOCKER" NGINX_CONFIG="$NGINX_CONFIG"
    restore_env
    cp -p .env "$env_backup"

    set_env_value REVERB_ALLOWED_ORIGINS 'http://invalid.example.test'
    run_case reverb_origin_url_format fail 'REVERB_ALLOWED_ORIGINS harus berisi hostname eksplisit' \
        SECURITY_GATE_PROFILE=production CHECK_HTTP=false CHECK_DOCKER="$CHECK_DOCKER" NGINX_CONFIG="$NGINX_CONFIG"
    restore_env
    cp -p .env "$env_backup"

    set_env_value APP_DEBUG true
    run_case app_debug_enabled fail 'APP_DEBUG harus false pada profile production.' \
        SECURITY_GATE_PROFILE=production CHECK_HTTP=false CHECK_DOCKER="$CHECK_DOCKER" NGINX_CONFIG="$NGINX_CONFIG"
    restore_env
    cp -p .env "$env_backup"

    chmod 644 .env
    run_case env_world_readable fail '.env dapat diakses oleh pengguna lain' \
        SECURITY_GATE_PROFILE=production CHECK_HTTP=false CHECK_DOCKER="$CHECK_DOCKER" NGINX_CONFIG="$NGINX_CONFIG"
    restore_env
    cp -p .env "$env_backup"

    if [[ -r "$NGINX_CONFIG" ]]; then
        nginx_fixture="$(mktemp .security-gate-nginx.XXXXXX.conf)"
        grep -v 'Permissions-Policy' "$NGINX_CONFIG" > "$nginx_fixture"
        run_case nginx_permissions_policy_missing fail 'Template Nginx belum memiliki Permissions-Policy.' \
            SECURITY_GATE_PROFILE=production CHECK_HTTP=false CHECK_DOCKER="$CHECK_DOCKER" NGINX_CONFIG="$nginx_fixture"
        rm -f "$nginx_fixture"
        nginx_fixture=""
    else
        printf '%s,%s,nginx_permissions_policy_missing,fail,not-run,not-run,0\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$run_index" >> "$REPORT_FILE"
        printf 'run=%s %-24s expected=fail detected=not-run duration_ms=0\n' "$run_index" 'nginx_permissions_policy_missing'
        unexpected=$((unexpected + 1))
    fi
done

printf '\nLaporan CSV: %s\n' "$REPORT_FILE"
printf 'Log per skenario: %s\n' "$LOG_DIR"

if (( unexpected > 0 )); then
    printf '%d skenario tidak menghasilkan keluaran yang diharapkan.\n' "$unexpected" >&2
    exit 1
fi
