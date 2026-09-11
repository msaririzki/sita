#!/usr/bin/env bash
set -Eeuo pipefail

# One entry point for the two SITA deployment environments.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    blue='\033[38;5;39m'
    cyan='\033[38;5;51m'
    green='\033[38;5;48m'
    yellow='\033[38;5;220m'
    red='\033[38;5;203m'
    dim='\033[2m'
    bold='\033[1m'
    reset='\033[0m'
else
    blue=''
    cyan=''
    green=''
    yellow=''
    red=''
    dim=''
    bold=''
    reset=''
fi

line() {
    printf '%b------------------------------------------------------------%b\n' "$dim" "$reset"
}

title() {
    printf '\n%b%s%b\n' "$bold$blue" ' SITA DEPLOYMENT CONSOLE' "$reset"
    printf '%bPilih environment deployment%b\n' "$dim" "$reset"
    line
    printf '  Project  %s\n' "$PROJECT_ROOT"
    line
}

show_tutorial() {
    printf '\n%b%s%b\n' "$bold$cyan" 'PANDUAN KONSOL DEPLOYMENT SITA' "$reset"
    line
    printf '%b[1] Docker%b digunakan pada server yang menjalankan stack Compose: database,\n' "$bold$blue" "$reset"
    printf 'app, web, queue, scheduler, dan Reverb berada dalam container.\n\n'
    printf '%b[2] aaPanel%b digunakan pada server dengan Nginx, PHP-FPM, database, dan\n' "$bold$blue" "$reset"
    printf 'Website yang dikelola melalui GUI aaPanel.\n\n'
    printf 'Kedua menu memakai Security Gate dan Integration Gate, tetapi pemeriksaan\n'
    printf 'infrastruktur tetap mengikuti environment masing-masing.\n\n'
    printf '%bPerintah langsung%b\n' "$bold$blue" "$reset"
    printf '  bash deploy/sita.sh docker check\n'
    printf '  bash deploy/sita.sh docker release\n'
    printf '  bash deploy/sita.sh aapanel check\n'
    printf '  bash deploy/sita.sh aapanel release\n\n'
    printf '%bKompatibilitas%b\n' "$bold$yellow" "$reset"
    printf 'Perintah lama bash deploy/sita.sh check tetap diarahkan ke aaPanel.\n'
}

run_environment() {
    local environment="$1"
    shift

    case "$environment" in
        docker) bash "$PROJECT_ROOT/deploy/sita-docker.sh" "$@" ;;
        aapanel) bash "$PROJECT_ROOT/deploy/sita-aapanel.sh" "$@" ;;
        *)
            printf 'Environment harus docker atau aapanel.\n' >&2
            exit 2
            ;;
    esac
}

if [ "${1:-}" != '' ]; then
    case "$1" in
        docker|aapanel)
            environment="$1"
            shift
            run_environment "$environment" "$@"
            exit $?
            ;;
        init|bootstrap|check|release)
            # Preserve the former aaPanel command contract.
            run_environment aapanel "$@"
            exit $?
            ;;
        help|--help|-h)
            show_tutorial
            exit 0
            ;;
        *)
            printf 'Penggunaan: bash deploy/sita.sh [docker|aapanel] [init|bootstrap|check|release]\n' >&2
            exit 2
            ;;
    esac
fi

while true; do
    title
    printf '\n'
    printf '  %b[1]%b  Docker                 %bCompose, container, dan gateway Docker%b\n' "$cyan" "$reset" "$dim" "$reset"
    printf '  %b[2]%b  aaPanel                %bGUI panel, PHP-FPM, dan service host%b\n' "$cyan" "$reset" "$dim" "$reset"
    printf '  %b[3]%b  Panduan lintas-environment\n' "$cyan" "$reset"
    printf '  %b[0]%b  Keluar\n\n' "$cyan" "$reset"

    read -r -p 'Pilih environment: ' choice
    case "$choice" in
        1) run_environment docker; continue ;;
        2) run_environment aapanel; continue ;;
        3) show_tutorial ;;
        0) exit 0 ;;
        *) printf '%bPilihan tidak tersedia.%b\n' "$red" "$reset" ;;
    esac

    printf '\nTekan Enter untuk kembali ke menu...'
    read -r _
done
