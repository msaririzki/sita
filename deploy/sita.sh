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
    printf '  [2] Bootstrap server baru\n'
    printf '      Dipakai sekali untuk deploy awal setelah Check lulus. Menjalankan\n'
    printf '      deploy awal dan memasang service Reverb, queue, serta scheduler.\n\n'
    printf '  [4] Release update aplikasi\n'
    printf '      Dipakai setiap ada pembaruan kode. Menjalankan pemeriksaan awal,\n'
    printf '      deploy, pemeriksaan integrasi, dan Security Gate.\n\n'

    printf '%bMenu pendukung%b\n' "$bold$blue" "$reset"
    printf '  [5] Membuka 80 baris terakhir log deployment.\n'
    printf '  [6] Menampilkan profile aktif untuk memastikan target server benar.\n'
    printf '  [7] Membuka panduan ini.\n\n'

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
    printf '  %b[2]%b  Bootstrap server baru     %bDeploy awal dan instal service%b\n' "$cyan" "$reset" "$dim" "$reset"
    printf '  %b[3]%b  Check kesiapan server     %bPemeriksaan tanpa perubahan%b\n' "$cyan" "$reset" "$dim" "$reset"
    printf '  %b[4]%b  Release update aplikasi   %bDeploy update + integration/security gate%b\n' "$cyan" "$reset" "$dim" "$reset"
    printf '  %b[5]%b  Lihat log terakhir\n' "$cyan" "$reset"
    printf '  %b[6]%b  Lihat profile aktif\n' "$cyan" "$reset"
    printf '  %b[7]%b  Panduan dan alur penggunaan\n' "$cyan" "$reset"
    printf '  %b[0]%b  Keluar\n\n' "$cyan" "$reset"

    read -r -p 'Pilih menu: ' choice
    case "$choice" in
        1) create_profile ;;
        2) run_action bootstrap ;;
        3) run_action check ;;
        4) run_action release ;;
        5) show_last_log ;;
        6) show_profile ;;
        7) show_tutorial ;;
        0) exit 0 ;;
        *) printf '%bPilihan tidak tersedia.%b\n' "$red" "$reset" ;;
    esac

    printf '\nTekan Enter untuk kembali ke menu...'
    read -r _
done
