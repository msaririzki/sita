#!/usr/bin/env bash
set -Eeuo pipefail

# Terminal entry point for aaPanel operators. All deployment logic remains in
# focused scripts; this file provides a memorable interactive interface.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_FILE="${AAPANEL_PROFILE_FILE:-${PROJECT_ROOT}/deploy/aapanel-profile.env}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    cyan='\033[36m'
    green='\033[32m'
    yellow='\033[33m'
    red='\033[31m'
    reset='\033[0m'
else
    cyan=''
    green=''
    yellow=''
    red=''
    reset=''
fi

title() {
    printf '\n%b+----------------------------------------------+%b\n' "$cyan" "$reset"
    printf '%b|        SITA DEPLOYMENT CONSOLE - aaPanel      |%b\n' "$cyan" "$reset"
    printf '%b+----------------------------------------------+%b\n' "$cyan" "$reset"
    printf 'Project: %s\n' "$PROJECT_ROOT"
}

create_profile() {
    local domain public_url

    if [ -f "$PROFILE_FILE" ]; then
        printf '%bProfile sudah tersedia:%b %s\n' "$yellow" "$reset" "$PROFILE_FILE"
        return
    fi

    printf '\nMembuat profile lokal tanpa rahasia.\n'
    read -r -p 'Domain SITA (contoh sita.kampus.ac.id): ' domain
    if [[ ! "$domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
        printf '%bDomain tidak valid.%b\n' "$red" "$reset" >&2
        return 1
    fi

    read -r -p 'URL publik [https://'"$domain"']: ' public_url
    public_url="${public_url:-https://${domain}}"
    public_url="${public_url%/}"

    cat > "$PROFILE_FILE" <<EOF
# Dibuat oleh deploy/sita.sh. Tidak berisi password atau secret Laravel.
DOMAIN=${domain}
APP_DIR=${PROJECT_ROOT}
PHP_BIN=/www/server/php/84/bin/php
PHP_FPM_SERVICE=php-fpm-84
PHP_FPM_RUNTIME_USER=www
PHP_FPM_RUNTIME_GROUP=www
PHP_FPM_SOCKET=/tmp/php-cgi-84.sock
NGINX_CONFIG=/www/server/panel/vhost/nginx/${domain}.conf
HEALTHCHECK_URL=${public_url}/up
PUBLIC_BASE_URL=${public_url}

# Ubah menjadi true hanya setelah migration direview dan backup database ada.
RUN_MIGRATIONS=false
RUN_DEPENDENCY_AUDIT=false
DEPENDENCY_AUDIT_MODE=report
DEPENDENCY_AUDIT_THRESHOLD=high
EOF
    chmod 600 "$PROFILE_FILE"
    printf '%bProfile dibuat:%b %s\n' "$green" "$reset" "$PROFILE_FILE"
    printf 'Isi .env secara terpisah; profile ini sengaja tidak menyimpan secret.\n'
}

run_action() {
    local action="$1"
    if [ ! -f "$PROFILE_FILE" ]; then
        printf '%bProfile belum ada. Pilih "Buat profile" terlebih dahulu.%b\n' "$yellow" "$reset" >&2
        return 1
    fi

    exec bash "$PROJECT_ROOT/deploy/aapanel-release.sh" "$action"
}

show_last_log() {
    local latest
    latest="$(ls -1t "$PROJECT_ROOT"/storage/logs/deployment/aapanel-*.log 2>/dev/null | head -n 1 || true)"
    if [ -z "$latest" ]; then
        printf '%bBelum ada log deployment.%b\n' "$yellow" "$reset"
        return
    fi

    printf '\nLog terakhir: %s\n\n' "$latest"
    tail -n 80 "$latest"
}

show_profile() {
    if [ -f "$PROFILE_FILE" ]; then
        printf '\nProfile aktif: %s\n' "$PROFILE_FILE"
        cat "$PROFILE_FILE"
    else
        printf '%bProfile belum dibuat.%b\n' "$yellow" "$reset"
    fi
}

run_non_interactive() {
    case "$1" in
        bootstrap|check|release) run_action "$1" ;;
        init) create_profile ;;
        *)
            printf 'Penggunaan: bash deploy/sita.sh [bootstrap|check|release|init]\n' >&2
            exit 2
            ;;
    esac
}

if [ "${1:-}" != '' ]; then
    run_non_interactive "$1"
    exit
fi

while true; do
    title
    printf '\n'
    printf '  %b1%b  Buat profile server (sekali, tanpa secret)\n' "$cyan" "$reset"
    printf '  %b2%b  Bootstrap server baru (deploy awal dan install service)\n' "$cyan" "$reset"
    printf '  %b3%b  Check kesiapan server tanpa perubahan\n' "$cyan" "$reset"
    printf '  %b4%b  Release update aplikasi\n' "$cyan" "$reset"
    printf '  %b5%b  Lihat log deployment terakhir\n' "$cyan" "$reset"
    printf '  %b6%b  Lihat profile aktif\n' "$cyan" "$reset"
    printf '  %b0%b  Keluar\n\n' "$cyan" "$reset"

    read -r -p 'Pilih menu: ' choice
    case "$choice" in
        1) create_profile ;;
        2) run_action bootstrap ;;
        3) run_action check ;;
        4) run_action release ;;
        5) show_last_log ;;
        6) show_profile ;;
        0) exit 0 ;;
        *) printf '%bPilihan tidak tersedia.%b\n' "$red" "$reset" ;;
    esac

    printf '\nTekan Enter untuk kembali ke menu...'
    read -r _
done
