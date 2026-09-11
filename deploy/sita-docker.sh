#!/usr/bin/env bash
set -Eeuo pipefail

# Docker operator console. Invoked by deploy/sita.sh or directly.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_FILE="${DOCKER_PROFILE_FILE:-${PROJECT_ROOT}/deploy/docker-profile.env}"
COMPOSE_FILES=(-f docker-compose.yml -f docker-compose.deploy.yml)

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

status_label() {
    local label="$1" value="$2" color="$3"
    printf '  %-20s %b%s%b\n' "$label" "$color" "$value" "$reset"
}

profile_value() {
    local key="$1"
    [ -f "$PROFILE_FILE" ] || return
    grep -E "^${key}=" "$PROFILE_FILE" | tail -n 1 | cut -d '=' -f 2-
}

latest_deployment_log() {
    ls -1t "$PROJECT_ROOT"/storage/logs/deployment/docker-*.log 2>/dev/null | head -n 1 || true
}

workspace_status() {
    local branch working_tree

    if [ -f "$PROFILE_FILE" ]; then
        status_label 'Profile Docker' 'SIAP' "$green"
    else
        status_label 'Profile Docker' 'BELUM DIBUAT' "$yellow"
    fi

    if [ -f "$PROJECT_ROOT/.env" ]; then
        status_label '.env Laravel' 'TERSEDIA' "$green"
    else
        status_label '.env Laravel' 'BELUM ADA' "$yellow"
    fi

    if command -v docker >/dev/null 2>&1; then
        status_label 'Docker CLI' 'TERSEDIA' "$green"
    else
        status_label 'Docker CLI' 'TIDAK TERSEDIA' "$red"
    fi

    if [ -d "$PROJECT_ROOT/.git" ]; then
        branch="$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || true)"
        if [ -n "$branch" ]; then
            status_label 'Git branch' "$branch" "$cyan"
        fi
        working_tree="$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null || true)"
        if [ -z "$working_tree" ]; then
            status_label 'Working tree' 'BERSIH' "$green"
        else
            status_label 'Working tree' 'ADA PERUBAHAN LOKAL' "$yellow"
        fi
    fi
}

title() {
    printf '\n%b%s%b\n' "$bold$blue" ' SITA DEPLOYMENT CONSOLE' "$reset"
    printf '%bDocker deployment and Security Gate%b\n' "$dim" "$reset"
    line
    printf '  Project              %s\n' "$PROJECT_ROOT"
    workspace_status
    line
}

create_profile() {
    local public_url
    if [ -f "$PROFILE_FILE" ]; then
        printf '%bProfile Docker sudah tersedia:%b %s\n' "$yellow" "$reset" "$PROFILE_FILE"
        return
    fi

    printf '\nMembuat profile Docker lokal tanpa secret.\n'
    read -r -p 'URL publik Docker [http://127.0.0.1:8088]: ' public_url
    public_url="${public_url:-http://127.0.0.1:8088}"
    public_url="${public_url%/}"
    if [[ ! "$public_url" =~ ^https?://[^[:space:]]+$ ]]; then
        printf '%bURL tidak valid. Gunakan http:// atau https://.%b\n' "$red" "$reset" >&2
        return 1
    fi

    cat > "$PROFILE_FILE" <<EOF
# Dibuat oleh deploy/sita-docker.sh. Tidak berisi password atau secret Laravel.
HEALTHCHECK_URL=${public_url}/up
PUBLIC_BASE_URL=${public_url}
NGINX_CONFIG=docker/nginx/default.conf
RUN_DEPENDENCY_AUDIT=false
DEPENDENCY_AUDIT_MODE=report
DEPENDENCY_AUDIT_THRESHOLD=high
EOF
    chmod 600 "$PROFILE_FILE"
    printf '%bProfile Docker dibuat:%b %s\n' "$green" "$reset" "$PROFILE_FILE"
}

run_action() {
    local action="$1"
    if [ ! -f "$PROFILE_FILE" ]; then
        printf '%bProfile Docker belum ada. Pilih "Buat profile Docker" terlebih dahulu.%b\n' "$yellow" "$reset" >&2
        return 1
    fi
    bash "$PROJECT_ROOT/deploy/docker-release.sh" "$action"
}

show_action_result() {
    case "$1" in
        check)
            printf '\n%b%s%b\n' "$bold$green" 'CHECK DOCKER SELESAI - SIAP UNTUK UPDATE' "$reset"
            printf 'Pilih %b[3] Release update Docker%b untuk membangun dan menjalankan update aplikasi.\n' "$cyan" "$reset"
            ;;
        release)
            printf '\n%b%s%b\n' "$bold$green" 'RELEASE DOCKER SELESAI' "$reset"
            printf 'Pilih %b[4] Status container dan aplikasi%b untuk memeriksa kondisi terkini.\n' "$cyan" "$reset"
            ;;
    esac
}

show_action_failure() {
    local latest
    latest="$(latest_deployment_log)"
    printf '\n%b%s%b\n' "$bold$red" 'AKSI DOCKER BELUM DINYATAKAN SIAP' "$reset"
    printf 'Periksa item [FAIL] pada output di atas sebelum mengulangi tindakan.\n'
    if [ -n "$latest" ]; then
        printf 'Log lengkap: %s\n' "$latest"
    fi
}

show_status() {
    local health_url service container_id state latest warning_count
    printf '\n%b%s%b\n' "$bold$cyan" 'STATUS CONTAINER DAN APLIKASI' "$reset"
    line
    if [ ! -f "$PROFILE_FILE" ]; then
        printf '%bProfile Docker belum dibuat.%b\n' "$yellow" "$reset"
        return
    fi

    health_url="$(profile_value HEALTHCHECK_URL)"
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS --max-time 5 "$health_url" >/dev/null 2>&1; then
            status_label 'Health endpoint' "HTTP 200 (${health_url})" "$green"
        else
            status_label 'Health endpoint' "TIDAK TERHUBUNG (${health_url})" "$red"
        fi
    fi

    if command -v docker >/dev/null 2>&1; then
        for service in db app web queue scheduler reverb; do
            container_id="$(docker compose "${COMPOSE_FILES[@]}" ps -q "$service" 2>/dev/null || true)"
            if [ -z "$container_id" ]; then
                status_label "Container ${service}" 'TIDAK DITEMUKAN' "$red"
                continue
            fi
            state="$(docker inspect -f '{{.State.Status}}' "$container_id" 2>/dev/null || true)"
            if [ "$state" = 'running' ]; then
                status_label "Container ${service}" 'BERJALAN' "$green"
            else
                status_label "Container ${service}" "${state:-TIDAK DIKETAHUI}" "$red"
            fi
        done
    fi

    latest="$(latest_deployment_log)"
    if [ -n "$latest" ]; then
        printf '  Log terakhir          %s\n' "$latest"
        warning_count="$(grep -Ec '^\[WARN\]|^WARN ' "$latest" 2>/dev/null || true)"
        if [ "${warning_count:-0}" -gt 0 ]; then
            status_label 'Peringatan log' "${warning_count} - lihat menu [5]" "$yellow"
        else
            status_label 'Peringatan log' 'TIDAK ADA' "$green"
        fi
    else
        status_label 'Deployment terakhir' 'BELUM ADA LOG' "$yellow"
    fi
    line
    printf '%bStatus ini hanya membaca kondisi Docker saat ini.%b\n' "$dim" "$reset"
}

show_last_log() {
    local latest
    latest="$(latest_deployment_log)"
    if [ -z "$latest" ]; then
        printf '%bBelum ada log Docker.%b\n' "$yellow" "$reset"
        return
    fi
    printf '\nLog terakhir: %s\n\n' "$latest"
    tail -n 80 "$latest"
}

show_tutorial() {
    printf '\n%b%s%b\n' "$bold$cyan" 'PANDUAN DOCKER DEPLOYMENT CONSOLE' "$reset"
    line
    printf '  [1] Buat profile Docker sekali untuk menyimpan URL lab tanpa secret.\n'
    printf '  [2] Check Docker memeriksa Compose, container, health, storage, Reverb,\n'
    printf '      WebSocket, dan Security Gate tanpa build atau restart container.\n'
    printf '  [3] Release Docker melakukan preflight, build image, init/migrasi,\n'
    printf '      restart service, integration gate, dan security gate.\n'
    printf '  [4] Status hanya membaca health endpoint dan kondisi enam container.\n\n'
    printf '%bMigration dapat dijalankan service init saat release. Tinjau migration dan backup database sebelum release.%b\n' "$yellow" "$reset"
}

run_non_interactive() {
    case "$1" in
        init) create_profile ;;
        check|release) run_action "$1" ;;
        *)
            printf 'Penggunaan: bash deploy/sita-docker.sh [init|check|release]\n' >&2
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
    printf '  %b[1]%b  Buat profile Docker      %bSekali per host, tanpa secret%b\n' "$cyan" "$reset" "$dim" "$reset"
    printf '  %b[2]%b  Check Docker             %bPemeriksaan tanpa perubahan%b\n' "$cyan" "$reset" "$dim" "$reset"
    printf '  %b[3]%b  Release update Docker    %bBuild, deploy, dan gate%b\n' "$cyan" "$reset" "$dim" "$reset"
    printf '  %b[4]%b  Status container dan aplikasi\n' "$cyan" "$reset"
    printf '  %b[5]%b  Lihat log Docker terakhir\n' "$cyan" "$reset"
    printf '  %b[6]%b  Panduan Docker\n' "$cyan" "$reset"
    printf '  %b[0]%b  Kembali ke pemilihan environment\n\n' "$cyan" "$reset"

    read -r -p 'Pilih menu Docker: ' choice
    case "$choice" in
        1) create_profile ;;
        2) if run_action check; then show_action_result check; else show_action_failure; fi ;;
        3) if run_action release; then show_action_result release; else show_action_failure; fi ;;
        4) show_status ;;
        5) show_last_log ;;
        6) show_tutorial ;;
        0) exit 0 ;;
        *) printf '%bPilihan tidak tersedia.%b\n' "$red" "$reset" ;;
    esac

    printf '\nTekan Enter untuk kembali ke menu...'
    read -r _
done
