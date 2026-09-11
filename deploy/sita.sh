#!/usr/bin/env bash
set -Eeuo pipefail

# Terminal entry point for aaPanel operators. All deployment logic remains in
# focused scripts; this file provides a memorable interactive interface.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE_FILE="${AAPANEL_PROFILE_FILE:-${PROJECT_ROOT}/deploy/aapanel-profile.env}"

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
    local label="$1"
    local value="$2"
    local color="$3"

    printf '  %-16s %b%s%b\n' "$label" "$color" "$value" "$reset"
}

workspace_status() {
    if [ -f "$PROFILE_FILE" ]; then
        status_label 'Profile' 'SIAP' "$green"
    else
        status_label 'Profile' 'BELUM DIBUAT' "$yellow"
    fi

    if [ -f "$PROJECT_ROOT/.env" ]; then
        status_label '.env Laravel' 'TERSEDIA' "$green"
    else
        status_label '.env Laravel' 'BELUM ADA' "$yellow"
    fi

    if [ -d "$PROJECT_ROOT/.git" ]; then
        status_label 'Repository' 'TERDETEKSI' "$green"

        local branch working_tree line tracked_changes unknown_files panel_local_files
        branch="$(git -C "$PROJECT_ROOT" branch --show-current 2>/dev/null || true)"
        if [ -n "$branch" ]; then
            status_label 'Git branch' "$branch" "$cyan"
        fi

        working_tree="$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null || true)"
        tracked_changes=0
        unknown_files=0
        panel_local_files=0
        if [ -n "$working_tree" ]; then
            while IFS= read -r line; do
                case "$line" in
                    '?? .htaccess'|'?? .user.ini') panel_local_files=$((panel_local_files + 1)) ;;
                    '?? '*) unknown_files=$((unknown_files + 1)) ;;
                    *) tracked_changes=$((tracked_changes + 1)) ;;
                esac
            done <<< "$working_tree"
        fi

        if [ "$tracked_changes" -gt 0 ]; then
            status_label 'Working tree' "PERUBAHAN GIT (${tracked_changes})" "$yellow"
        elif [ "$unknown_files" -gt 0 ]; then
            status_label 'Working tree' "FILE LOKAL BARU (${unknown_files})" "$yellow"
        elif [ "$panel_local_files" -gt 0 ]; then
            status_label 'Working tree' 'HANYA FILE PANEL LOKAL' "$green"
            status_label 'File aaPanel lokal' "TERDETEKSI (${panel_local_files})" "$cyan"
        else
            status_label 'Working tree' 'BERSIH' "$green"
        fi
    else
        status_label 'Repository' 'TIDAK TERDETEKSI' "$yellow"
    fi
}

title() {
    printf '\n%b%s%b\n' "$bold$blue" ' SITA DEPLOYMENT CONSOLE' "$reset"
    printf '%bDeployment and Security Gate for aaPanel%b\n' "$dim" "$reset"
    line
    printf '  Project          %s\n' "$PROJECT_ROOT"
    workspace_status
    line
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

    bash "$PROJECT_ROOT/deploy/aapanel-release.sh" "$action"
}

show_action_result() {
    local action="$1"

    case "$action" in
        check)
            printf '\n%b%s%b\n' "$bold$green" 'CHECK SELESAI - SERVER SIAP UNTUK UPDATE' "$reset"
            printf 'Jika ingin memperbarui kode aplikasi sekarang, kembali ke menu lalu pilih %b[4] Release update aplikasi%b.\n' "$cyan" "$reset"
            printf 'Jika ini server baru, selesaikan konfigurasi GUI dan .env, lalu pilih %b[2] Siapkan server baru%b.\n' "$cyan" "$reset"
            ;;
        bootstrap)
            printf '\n%b%s%b\n' "$bold$green" 'DEPLOY AWAL SELESAI' "$reset"
            printf 'Untuk pembaruan berikutnya, pilih %b[4] Release update aplikasi%b.\n' "$cyan" "$reset"
            ;;
        release)
            printf '\n%b%s%b\n' "$bold$green" 'RELEASE SELESAI' "$reset"
            printf 'Aplikasi sudah melalui pemeriksaan integrasi dan Security Gate. Gunakan %b[5]%b bila ingin membaca log terakhir.\n' "$cyan" "$reset"
            ;;
    esac
}

latest_deployment_log() {
    ls -1t "$PROJECT_ROOT"/storage/logs/deployment/aapanel-*.log 2>/dev/null | head -n 1 || true
}

profile_value() {
    local key="$1"

    if [ ! -f "$PROFILE_FILE" ]; then
        return
    fi

    grep -E "^${key}=" "$PROFILE_FILE" | tail -n 1 | cut -d '=' -f 2-
}

show_action_failure() {
    local action="$1" latest

    latest="$(latest_deployment_log)"
    printf '\n%b%s%b\n' "$bold$red" "${action^^} BELUM DINYATAKAN SIAP" "$reset"
    printf 'Periksa item [FAIL] pada output di atas sebelum mengulangi tindakan.\n'
    if [ -n "$latest" ]; then
        printf 'Log lengkap: %s\n' "$latest"
    fi
    printf 'Pilih %b[8] Status aplikasi dan runtime%b untuk memeriksa kondisi setelah kegagalan.\n' "$cyan" "$reset"
}

show_last_log() {
    local latest
    latest="$(latest_deployment_log)"
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
        printf '  DOMAIN=%s\n' "$(profile_value DOMAIN)"
        printf '  APP_DIR=%s\n' "$(profile_value APP_DIR)"
        printf '  PHP_BIN=%s\n' "$(profile_value PHP_BIN)"
        printf '  PHP_FPM_SERVICE=%s\n' "$(profile_value PHP_FPM_SERVICE)"
        printf '  PHP_FPM_SOCKET=%s\n' "$(profile_value PHP_FPM_SOCKET)"
        printf '  NGINX_CONFIG=%s\n' "$(profile_value NGINX_CONFIG)"
        printf '  HEALTHCHECK_URL=%s\n' "$(profile_value HEALTHCHECK_URL)"
        printf '  RUN_MIGRATIONS=%s\n' "$(profile_value RUN_MIGRATIONS)"
        printf '  RUN_DEPENDENCY_AUDIT=%s\n' "$(profile_value RUN_DEPENDENCY_AUDIT)"
        printf '%bHanya field operasional ditampilkan; profile tidak boleh menyimpan secret.%b\n' "$dim" "$reset"
    else
        printf '%bProfile belum dibuat.%b\n' "$yellow" "$reset"
    fi
}

show_operational_status() {
    local domain health_url service slug state http_status latest log_status warning_count

    printf '\n%b%s%b\n' "$bold$cyan" 'STATUS APLIKASI DAN RUNTIME' "$reset"
    line

    if [ ! -f "$PROFILE_FILE" ]; then
        printf '%bProfile belum dibuat. Status runtime tidak dapat ditentukan.%b\n' "$yellow" "$reset"
        return
    fi

    domain="$(profile_value DOMAIN)"
    health_url="$(profile_value HEALTHCHECK_URL)"
    service="$(profile_value PHP_FPM_SERVICE)"
    slug="$(printf '%s' "$domain" | tr -cs 'A-Za-z0-9' '-')"

    if command -v curl >/dev/null 2>&1 && [ -n "$health_url" ]; then
        http_status="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "$health_url" 2>/dev/null || true)"
        if [ "$http_status" = '200' ]; then
            status_label 'Health endpoint' "HTTP 200 (${health_url})" "$green"
        else
            status_label 'Health endpoint' "HTTP ${http_status:-tidak-terhubung} (${health_url})" "$red"
        fi
    else
        status_label 'Health endpoint' 'TIDAK DAPAT DIPERIKSA' "$yellow"
    fi

    for service in "$service" "sita-${slug}-reverb.service" "sita-${slug}-queue.service" "sita-${slug}-schedule.timer"; do
        if [ -z "$service" ]; then
            continue
        fi

        state="$(systemctl is-active "$service" 2>/dev/null || true)"
        if [ "$state" = 'active' ]; then
            status_label "$service" 'AKTIF' "$green"
        else
            status_label "$service" "${state:-TIDAK TERDETEKSI}" "$red"
        fi
    done

    latest="$(latest_deployment_log)"
    if [ -z "$latest" ]; then
        status_label 'Deployment terakhir' 'BELUM ADA LOG' "$yellow"
    elif grep -q 'RILIS DINYATAKAN SIAP\|DEPLOY AWAL DINYATAKAN SIAP\|BOOTSTRAP DINYATAKAN SIAP\|PEMERIKSAAN DINYATAKAN SIAP' "$latest"; then
        log_status="$(grep -E 'RILIS DINYATAKAN SIAP|DEPLOY AWAL DINYATAKAN SIAP|BOOTSTRAP DINYATAKAN SIAP|PEMERIKSAAN DINYATAKAN SIAP' "$latest" | tail -n 1)"
        status_label 'Deployment terakhir' "$log_status" "$green"
        printf '  Log terakhir      %s\n' "$latest"
    else
        status_label 'Deployment terakhir' 'PERLU DITINJAU' "$yellow"
        printf '  Log terakhir      %s\n' "$latest"
    fi

    if [ -n "$latest" ]; then
        warning_count="$(grep -Ec '^\[WARN\]|^WARN ' "$latest" 2>/dev/null || true)"
        if [ "${warning_count:-0}" -gt 0 ]; then
            status_label 'Peringatan log' "${warning_count} - lihat menu [5]" "$yellow"
        else
            status_label 'Peringatan log' 'TIDAK ADA' "$green"
        fi
    fi

    line
    printf '%bStatus ini hanya membaca kondisi saat ini; tidak mengubah aplikasi atau aaPanel.%b\n' "$dim" "$reset"
}

show_tutorial() {
    printf '\n%b%s%b\n' "$bold$cyan" 'PANDUAN PENGGUNAAN SITA DEPLOYMENT CONSOLE' "$reset"
    line
    printf '%bTujuan konsol ini%b\n' "$bold" "$reset"
    printf 'Membuat deployment SITA di aaPanel lebih konsisten, dapat diperiksa,\n'
    printf 'dan memiliki log yang dapat dipakai sebagai bukti pengujian skripsi.\n\n'

    printf '%bTahap 0 - Siapkan melalui GUI aaPanel (sekali per server)%b\n' "$bold$blue" "$reset"
    printf '  1. Instal Nginx dan PHP 8.4 dari App Store aaPanel.\n'
    printf '  2. Tambahkan Website dengan domain/IP dan arahkan path ke folder proyek.\n'
    printf '  3. Buat database serta pengguna database khusus SITA.\n'
    printf '  4. Atur root Nginx ke folder public dan gunakan socket PHP 8.4 yang benar.\n'
    printf '  5. Untuk domain publik, aktifkan SSL setelah DNS mengarah ke server.\n\n'

    printf '%bTahap 1 - Siapkan kode dan rahasia aplikasi%b\n' "$bold$blue" "$reset"
    printf '  1. Clone repository ke folder tujuan, misalnya /www/wwwroot/webkampus/sita.\n'
    printf '  2. Buat .env dari .env.example dan isi APP_KEY, database, mail, dan Reverb.\n'
    printf '  3. Jangan menaruh password atau secret pada profile server maupun Git.\n\n'

    printf '%bTahap 2 - Jalankan konsol%b\n' "$bold$blue" "$reset"
    printf '  cd /lokasi/proyek/sita\n'
    printf '  bash deploy/sita.sh\n\n'

    printf '%bUrutan menu yang direkomendasikan%b\n' "$bold$blue" "$reset"
    printf '  [1] Buat profile server\n'
    printf '      Menyimpan lokasi proyek, domain, PHP-FPM, dan URL health check.\n'
    printf '      Dibuat sekali untuk setiap server. Tidak menyimpan rahasia.\n\n'
    printf '  [3] Check kesiapan server\n'
    printf '      Memeriksa sinkronisasi GUI aaPanel, PHP, extension, Nginx, .env,\n'
    printf '      permission runtime, dan service tanpa mengubah aplikasi.\n\n'
    printf '  [2] Siapkan server baru (deploy awal)\n'
    printf '      Dipakai sekali untuk deploy awal setelah Check lulus. Menjalankan\n'
    printf '      deploy awal dan memasang service Reverb, queue, serta scheduler.\n\n'
    printf '  [4] Release update aplikasi\n'
    printf '      Dipakai setiap ada pembaruan kode. Menjalankan pemeriksaan awal,\n'
    printf '      deploy, pemeriksaan integrasi, dan Security Gate.\n\n'

    printf '%bMenu pendukung%b\n' "$bold$blue" "$reset"
    printf '  [5] Membuka 80 baris terakhir log deployment.\n'
    printf '  [6] Menampilkan field profile aktif tanpa menampilkan secret.\n'
    printf '  [7] Membuka panduan ini.\n\n'
    printf '  [8] Menampilkan status health endpoint, service, dan hasil log terakhir.\n\n'

    printf '%bCatatan keamanan%b\n' "$bold$yellow" "$reset"
    printf '  - Release berhenti bila pemeriksaan penting gagal; perbaiki penyebabnya dahulu.\n'
    printf '  - Migration tidak otomatis dijalankan karena RUN_MIGRATIONS=false.\n'
    printf '    Aktifkan hanya setelah migration direview dan backup database tersedia.\n'
    printf '  - PHP extension diperiksa oleh Check. Perubahan extension pada runtime PHP\n'
    printf '    yang dipakai situs lain harus dilakukan dengan hati-hati melalui aaPanel.\n\n'

    printf '%bHasil setiap proses%b\n' "$bold$blue" "$reset"
    printf '  Log lengkap tersimpan di storage/logs/deployment/aapanel-<aksi>-<waktu>.log\n'
    printf '  Simpan log yang lulus dan gagal sebagai data eksperimen skripsi.\n'
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
    printf '  %b[1]%b  Buat profile server       %bSekali per server, tanpa secret%b\n' "$cyan" "$reset" "$dim" "$reset"
    printf '  %b[2]%b  Siapkan server baru      %bDeploy awal dan aktifkan service%b\n' "$cyan" "$reset" "$dim" "$reset"
    printf '  %b[3]%b  Check kesiapan server     %bPemeriksaan tanpa perubahan%b\n' "$cyan" "$reset" "$dim" "$reset"
    printf '  %b[4]%b  Release update aplikasi   %bDeploy update + integration/security gate%b\n' "$cyan" "$reset" "$dim" "$reset"
    printf '  %b[5]%b  Lihat log terakhir\n' "$cyan" "$reset"
    printf '  %b[6]%b  Lihat profile aktif\n' "$cyan" "$reset"
    printf '  %b[7]%b  Panduan dan alur penggunaan\n' "$cyan" "$reset"
    printf '  %b[8]%b  Status aplikasi dan runtime\n' "$cyan" "$reset"
    printf '  %b[0]%b  Keluar\n\n' "$cyan" "$reset"

    read -r -p 'Pilih menu: ' choice
    case "$choice" in
        1) create_profile ;;
        2) if run_action bootstrap; then show_action_result bootstrap; else show_action_failure bootstrap; fi ;;
        3) if run_action check; then show_action_result check; else show_action_failure check; fi ;;
        4) if run_action release; then show_action_result release; else show_action_failure release; fi ;;
        5) show_last_log ;;
        6) show_profile ;;
        7) show_tutorial ;;
        8) show_operational_status ;;
        0) exit 0 ;;
        *) printf '%bPilihan tidak tersedia.%b\n' "$red" "$reset" ;;
    esac

    printf '\nTekan Enter untuk kembali ke menu...'
    read -r _
done
