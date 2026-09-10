#!/usr/bin/env bash

# Audit dependensi production tanpa mengubah lockfile atau memasang dependency.
# Mode report mencatat temuan; mode enforce memblokir jika ambang severity terpenuhi.
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

PHP_BIN="${PHP_BIN:-php}"
COMPOSER_BIN="${COMPOSER_BIN:-composer}"
NPM_BIN="${NPM_BIN:-npm}"
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

for command in "$PHP_BIN" "$COMPOSER_BIN" "$NPM_BIN"; do
    command -v "$command" >/dev/null 2>&1 || { printf 'Command wajib tidak tersedia: %s\n' "$command" >&2; exit 2; }
done

mkdir -p "$REPORT_DIR"
temporary_directory="$(mktemp -d)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
summary_file="${REPORT_DIR%/}/dependency-audit-${timestamp}.json"
trap 'rm -rf "$temporary_directory"' EXIT

composer_report="$temporary_directory/composer-audit.json"
npm_report="$temporary_directory/npm-audit.json"

printf 'Menjalankan Composer audit untuk dependency production...\n'
set +e
"$COMPOSER_BIN" audit --locked --no-dev --format=json --no-interaction --no-plugins --no-scripts > "$composer_report"
composer_exit=$?
set -e

printf 'Menjalankan npm audit untuk dependency production...\n'
set +e
"$NPM_BIN" audit --omit=dev --audit-level=none --json --ignore-scripts > "$npm_report"
npm_exit=$?
set -e

if [[ ! -s "$composer_report" || ! -s "$npm_report" ]]; then
    printf 'FAIL  Audit dependensi tidak menghasilkan laporan JSON lengkap (Composer=%s, npm=%s).\n' "$composer_exit" "$npm_exit" >&2
    exit 2
fi

"$PHP_BIN" scripts/dependency-audit-summary.php \
    --composer-report="$composer_report" \
    --npm-report="$npm_report" \
    --output="$summary_file" \
    --mode="$MODE" \
    --threshold="$THRESHOLD"
