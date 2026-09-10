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

if [[ "$RUNTIME" = 'host' ]]; then
    printf 'Menjalankan Composer audit untuk dependency production pada host...\n'
    set +e
    "$COMPOSER_BIN" audit --locked --no-dev --format=json --no-interaction --no-plugins --no-scripts > "$composer_report"
    composer_exit=$?
    set -e

    printf 'Menjalankan npm audit untuk dependency production pada host...\n'
    set +e
    "$NPM_BIN" audit --omit=dev --audit-level=none --json --ignore-scripts > "$npm_report"
    npm_exit=$?
    set -e
else
    printf 'Menjalankan Composer audit pada container sementara %s...\n' "$COMPOSER_AUDIT_IMAGE"
    set +e
    docker run --rm \
        --mount "type=bind,src=$PROJECT_ROOT,dst=/app,readonly" \
        --workdir /app \
        "$COMPOSER_AUDIT_IMAGE" audit --locked --no-dev --format=json --no-interaction --no-plugins --no-scripts > "$composer_report"
    composer_exit=$?
    set -e

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
