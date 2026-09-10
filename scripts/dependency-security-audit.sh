#!/usr/bin/env bash

# Audit dependensi production tanpa mengubah lockfile atau memasang dependency.
# Mode report mencatat temuan; mode enforce memblokir jika ambang severity terpenuhi.
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

PHP_BIN="${PHP_BIN:-php}"
COMPOSER_BIN="${COMPOSER_BIN:-composer}"
NPM_BIN="${NPM_BIN:-npm}"
RUNTIME="${DEPENDENCY_AUDIT_RUNTIME:-host}"
COMPOSER_AUDIT_IMAGE="${COMPOSER_AUDIT_IMAGE:-composer:2}"
NPM_AUDIT_IMAGE="${NPM_AUDIT_IMAGE:-node:22-alpine}"
COMPOSER_AUDIT_ATTEMPTS="${COMPOSER_AUDIT_ATTEMPTS:-3}"
MODE="${DEPENDENCY_AUDIT_MODE:-report}"
THRESHOLD="${DEPENDENCY_AUDIT_THRESHOLD:-high}"
REPORT_DIR="${DEPENDENCY_AUDIT_REPORT_DIR:-storage/app/security-gate-audits}"

if [[ "$MODE" != 'report' && "$MODE" != 'enforce' ]]; then
    printf 'DEPENDENCY_AUDIT_MODE harus report atau enforce.\n' >&2
    exit 2
fi

if [[ ! "$THRESHOLD" =~ ^(low|moderate|high|critical)$ ]]; then
    printf 'DEPENDENCY_AUDIT_THRESHOLD harus low, moderate, high, atau critical.\n' >&2
    exit 2
fi

if [[ "$RUNTIME" != 'host' && "$RUNTIME" != 'docker' ]]; then
    printf 'DEPENDENCY_AUDIT_RUNTIME harus host atau docker.\n' >&2
    exit 2
fi

if [[ ! "$COMPOSER_AUDIT_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
    printf 'COMPOSER_AUDIT_ATTEMPTS harus bilangan bulat positif.\n' >&2
    exit 2
fi

if [[ "$RUNTIME" = 'host' ]]; then
    for command in "$PHP_BIN" "$COMPOSER_BIN" "$NPM_BIN"; do
        command -v "$command" >/dev/null 2>&1 || { printf 'Command wajib tidak tersedia: %s\n' "$command" >&2; exit 2; }
    done
else
    command -v docker >/dev/null 2>&1 || { printf 'Docker wajib tersedia untuk DEPENDENCY_AUDIT_RUNTIME=docker.\n' >&2; exit 2; }
fi

mkdir -p "$REPORT_DIR"
report_directory_absolute="$(cd "$REPORT_DIR" && pwd)"
temporary_directory="$(mktemp -d)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
summary_name="dependency-audit-${timestamp}.json"
summary_file="${REPORT_DIR%/}/${summary_name}"
trap 'rm -rf "$temporary_directory"' EXIT

composer_report="$temporary_directory/composer-audit.json"
npm_report="$temporary_directory/npm-audit.json"

prepare_host_composer_audit() {
    if "$COMPOSER_BIN" audit --help >/dev/null 2>&1; then
        composer_audit_command=("$COMPOSER_BIN")
        return
    fi

    command -v curl >/dev/null 2>&1 || { printf 'curl wajib tersedia untuk Composer audit sementara.\n' >&2; exit 2; }
    command -v sha256sum >/dev/null 2>&1 || { printf 'sha256sum wajib tersedia untuk memverifikasi Composer sementara.\n' >&2; exit 2; }

    local composer_phar="$temporary_directory/composer.phar"
    local checksum_file="$temporary_directory/composer.phar.sha256sum"
    local expected_checksum actual_checksum

    printf 'Composer host belum mendukung audit; menggunakan Composer 2 sementara yang terverifikasi.\n' >&2
    curl -fsSL --retry 3 --connect-timeout 10 https://getcomposer.org/download/latest-stable/composer.phar -o "$composer_phar"
    curl -fsSL --retry 3 --connect-timeout 10 https://getcomposer.org/download/latest-stable/composer.phar.sha256sum -o "$checksum_file"
    expected_checksum="$(awk '{print $1}' "$checksum_file")"
    actual_checksum="$(sha256sum "$composer_phar" | awk '{print $1}')"

    if [[ -z "$expected_checksum" || "$expected_checksum" != "$actual_checksum" ]]; then
        printf 'FAIL  Checksum Composer sementara tidak sesuai; audit dihentikan.\n' >&2
        exit 2
    fi

    composer_audit_command=("$PHP_BIN" "$composer_phar")
}

if [[ "$RUNTIME" = 'host' ]]; then
    prepare_host_composer_audit
    printf 'Menjalankan Composer audit untuk dependency production pada host...\n'
    set +e
    "${composer_audit_command[@]}" audit --locked --no-dev --format=json --no-interaction --no-plugins --no-scripts > "$composer_report"
    composer_exit=$?
    set -e

    printf 'Menjalankan npm audit untuk dependency production pada host...\n'
    set +e
    "$NPM_BIN" audit --omit=dev --audit-level=none --json --ignore-scripts > "$npm_report"
    npm_exit=$?
    set -e
else
    printf 'Menjalankan Composer audit pada container sementara %s...\n' "$COMPOSER_AUDIT_IMAGE"
    composer_exit=100
    for attempt in $(seq 1 "$COMPOSER_AUDIT_ATTEMPTS"); do
        set +e
        docker run --rm \
            --env COMPOSER_IPRESOLVE=4 \
            --mount "type=bind,src=$PROJECT_ROOT,dst=/app,readonly" \
            --workdir /app \
            --entrypoint sh \
            "$COMPOSER_AUDIT_IMAGE" -c 'git config --global --add safe.directory /app && composer audit --locked --no-dev --format=json --no-interaction --no-plugins --no-scripts' > "$composer_report"
        composer_exit=$?
        set -e

        if [[ -s "$composer_report" && "$(head -c 1 "$composer_report")" = '{' ]]; then
            break
        fi

        if (( attempt < COMPOSER_AUDIT_ATTEMPTS )); then
            printf 'Composer audit belum memperoleh laporan; ulangi (%d/%d)...\n' "$attempt" "$COMPOSER_AUDIT_ATTEMPTS" >&2
            sleep "$attempt"
        fi
    done

    printf 'Menjalankan npm audit pada container sementara %s...\n' "$NPM_AUDIT_IMAGE"
    set +e
    docker run --rm \
        --mount "type=bind,src=$PROJECT_ROOT,dst=/app,readonly" \
        --workdir /app \
        "$NPM_AUDIT_IMAGE" npm audit --omit=dev --audit-level=none --json --ignore-scripts > "$npm_report"
    npm_exit=$?
    set -e
fi

if [[ ! -s "$composer_report" || ! -s "$npm_report" ]]; then
    printf 'FAIL  Audit dependensi tidak menghasilkan laporan JSON lengkap (Composer=%s, npm=%s).\n' "$composer_exit" "$npm_exit" >&2
    exit 2
fi

if [[ "$RUNTIME" = 'host' ]]; then
    "$PHP_BIN" scripts/dependency-audit-summary.php \
        --composer-report="$composer_report" \
        --npm-report="$npm_report" \
        --output="$summary_file" \
        --mode="$MODE" \
        --threshold="$THRESHOLD"
else
    docker run --rm \
        --user "$(id -u):$(id -g)" \
        --mount "type=bind,src=$PROJECT_ROOT,dst=/app,readonly" \
        --mount "type=bind,src=$temporary_directory,dst=/audit,readonly" \
        --mount "type=bind,src=$report_directory_absolute,dst=/reports" \
        --workdir /app \
        --entrypoint php \
        "$COMPOSER_AUDIT_IMAGE" scripts/dependency-audit-summary.php \
        --composer-report=/audit/composer-audit.json \
        --npm-report=/audit/npm-audit.json \
        --output="/reports/$summary_name" \
        --mode="$MODE" \
        --threshold="$THRESHOLD"
fi
