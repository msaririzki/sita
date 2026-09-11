#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only reconciliation between aaPanel's GUI-managed website and SITA's
# repository-managed deployment expectations. This script deliberately never
# writes aaPanel's SQLite database or vhost: GUI and SSL settings stay intact.

DOMAIN="${DOMAIN:?Isi DOMAIN, contoh: DOMAIN=sita.kampus.ac.id bash deploy/aapanel-sync.sh}"
APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PHP_BIN="${PHP_BIN:-/www/server/php/84/bin/php}"
PHP_FPM_RUNTIME_USER="${PHP_FPM_RUNTIME_USER:-www}"
PHP_FPM_SOCKET="${PHP_FPM_SOCKET:-}"
NGINX_CONFIG="${NGINX_CONFIG:-/www/server/panel/vhost/nginx/${DOMAIN}.conf}"
NGINX_VHOST_DIR="${NGINX_VHOST_DIR:-$(dirname "$NGINX_CONFIG")}"
NGINX_BIN="${NGINX_BIN:-/www/server/nginx/sbin/nginx}"
PANEL_DATABASE="${PANEL_DATABASE:-/www/server/panel/data/default.db}"
CHECK_SERVICES="${CHECK_SERVICES:-true}"

FAILED=0
WARNED=0

ok() {
    printf '[OK] %s\n' "$1"
}

warn() {
    printf '[WARN] %s\n' "$1"
    WARNED=1
}

fail() {
    printf '[FAIL] %s\n' "$1"
    FAILED=1
}

PHP_EXTENSIONS=''

read_php_extensions() {
    PHP_EXTENSIONS="$("$PHP_BIN" -m 2>/dev/null | tr '[:upper:]' '[:lower:]')"
}

php_extension_active() {
    local extension="$1"

    case $'\n'"$PHP_EXTENSIONS"$'\n' in
        *$'\n'"$extension"$'\n'*) return 0 ;;
        *) return 1 ;;
    esac
}

run_privileged() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
        return
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
        return
    fi

    return 1
}

run_as_runtime_user() {
    if [ "$EUID" -eq 0 ]; then
        runuser -u "$PHP_FPM_RUNTIME_USER" -- "$@"
        return
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo -u "$PHP_FPM_RUNTIME_USER" -- "$@"
        return
    fi

    return 1
}

read_privileged() {
    if [ -r "$1" ]; then
        cat "$1"
    else
        run_privileged cat "$1"
    fi
}

if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
    printf 'DOMAIN hanya boleh berisi huruf, angka, titik, dan tanda hubung.\n' >&2
    exit 2
fi

if [[ "$APP_DIR" != /* ]]; then
    printf 'APP_DIR harus berupa path absolut.\n' >&2
    exit 2
fi

if [ -z "$PHP_FPM_SOCKET" ]; then
    case "$PHP_BIN" in
        */php/[0-9][0-9]/bin/php)
            php_slot="$(printf '%s' "$PHP_BIN" | sed -E 's#^.*/php/([0-9][0-9])/bin/php$#\1#')"
            PHP_FPM_SOCKET="/tmp/php-cgi-${php_slot}.sock"
            ;;
        *)
            PHP_FPM_SOCKET="/tmp/php-cgi-84.sock"
            ;;
    esac
fi

if [[ "$PHP_FPM_SOCKET" != /tmp/php-cgi-[0-9][0-9].sock ]]; then
    printf 'PHP_FPM_SOCKET harus berupa socket aaPanel, contoh /tmp/php-cgi-84.sock.\n' >&2
    exit 2
fi

printf 'SITA aaPanel synchronization check\n'
printf 'Domain: %s\nApplication: %s\nNginx config: %s\n\n' "$DOMAIN" "$APP_DIR" "$NGINX_CONFIG"

if [ -d "$APP_DIR" ] && [ -f "$APP_DIR/artisan" ]; then
    ok "Direktori aplikasi dan artisan tersedia"
else
    fail "APP_DIR tidak mengarah ke root aplikasi Laravel"
fi

if command -v sqlite3 >/dev/null 2>&1 && run_privileged test -r "$PANEL_DATABASE"; then
    site_count="$(run_privileged sqlite3 "$PANEL_DATABASE" "SELECT COUNT(*) FROM sites WHERE name = '$DOMAIN';" 2>/dev/null || true)"
    if [ "$site_count" = '1' ]; then
        ok "Website terdaftar di GUI aaPanel: $DOMAIN"
    elif [ "$site_count" = '0' ]; then
        fail "Website belum terdaftar di aaPanel. Buat sekali melalui Website > Add site."
    else
        fail "Tidak dapat memverifikasi entri website aaPanel"
    fi
else
    warn "Database aaPanel tidak dapat dibaca. Jalankan dengan sudo untuk memverifikasi registrasi GUI."
fi

config_content=''
if config_content="$(read_privileged "$NGINX_CONFIG" 2>/dev/null)"; then
    ok "Vhost Nginx dapat dibaca"

    if grep -Fq "server_name ${DOMAIN}" <<<"$config_content"; then
        ok "server_name Nginx sesuai domain"
    else
        fail "server_name Nginx tidak memuat ${DOMAIN}"
    fi

    if grep -Fq "root ${APP_DIR}/public;" <<<"$config_content"; then
        ok "Document root Nginx mengarah ke public Laravel"
    else
        fail "Document root harus mengarah ke ${APP_DIR}/public"
    fi

    if grep -Fq "fastcgi_pass unix:${PHP_FPM_SOCKET};" <<<"$config_content"; then
        ok "Socket PHP-FPM sesuai: ${PHP_FPM_SOCKET}"
    else
        fail "Vhost belum memakai socket PHP-FPM yang diharapkan: ${PHP_FPM_SOCKET}"
    fi

    if grep -Fq 'proxy_pass http://127.0.0.1:8080;' <<<"$config_content"; then
        ok "Proxy Reverb tetap internal"
    else
        warn "Proxy Reverb internal tidak ditemukan. Wajib bila BROADCAST_CONNECTION=reverb."
    fi
else
    fail "Vhost Nginx tidak dapat dibaca: ${NGINX_CONFIG}"
fi

if [ -x "$NGINX_BIN" ]; then
    if run_privileged "$NGINX_BIN" -t >/dev/null 2>&1; then
        ok "Sintaks konfigurasi Nginx valid"
    else
        fail "Sintaks Nginx gagal. Jangan reload sebelum memperbaiki konfigurasi."
    fi
else
    warn "Binary Nginx aaPanel tidak ditemukan: ${NGINX_BIN}"
fi

socket_references="$(run_privileged grep -rl --include='*.conf' -F "fastcgi_pass unix:${PHP_FPM_SOCKET};" "$NGINX_VHOST_DIR" 2>/dev/null || true)"
matching_vhosts=''
while IFS= read -r vhost; do
    [ -n "$vhost" ] || continue

    # aaPanel's phpfpm_status.conf contains every PHP socket for local status
    # endpoints. It is not a website that shares the PHP runtime with SITA.
    if run_privileged grep -Eq '^[[:space:]]*server_name[[:space:]]+127\.0\.0\.1[[:space:]]*;' "$vhost"; then
        continue
    fi

    matching_vhosts+="${matching_vhosts:+$'\n'}${vhost}"
done <<< "$socket_references"
matching_count="$(printf '%s\n' "$matching_vhosts" | sed '/^$/d' | wc -l | tr -d ' ')"
if [ "$matching_count" -eq 1 ]; then
    ok "Runtime PHP ${PHP_FPM_SOCKET} hanya dipakai vhost SITA"
elif [ "$matching_count" -gt 1 ]; then
    warn "Runtime PHP ${PHP_FPM_SOCKET} dipakai ${matching_count} vhost. Jangan memasang/menghapus extension otomatis; perubahan berlaku global untuk PHP tersebut."
else
    warn "Tidak dapat menemukan pemakai socket ${PHP_FPM_SOCKET} pada vhost aaPanel"
fi

if [ -x "$PHP_BIN" ]; then
    if "$PHP_BIN" -r 'exit(version_compare(PHP_VERSION, "8.4.0", ">=") ? 0 : 1);' >/dev/null 2>&1; then
        ok "PHP CLI memenuhi minimal 8.4"
    else
        fail "PHP CLI belum memenuhi minimal 8.4"
    fi

    if read_php_extensions; then
        for extension in bcmath ctype dom fileinfo filter intl json mbstring openssl pcntl pcre pdo pdo_mysql session tokenizer xml zip; do
            if php_extension_active "$extension"; then
                ok "PHP extension aktif: ${extension}"
            else
                fail "PHP extension belum aktif: ${extension}. Aktifkan melalui aaPanel > App Store > PHP 8.4 > Install extensions."
            fi
        done
    else
        fail "Daftar PHP extension tidak dapat dibaca dari ${PHP_BIN}"
    fi
else
    fail "PHP CLI aaPanel tidak ditemukan: ${PHP_BIN}"
fi

if [ -f "$APP_DIR/.env" ]; then
    env_mode="$(stat -Lc '%a' "$APP_DIR/.env" 2>/dev/null || true)"
    if [ -n "$env_mode" ] && [ $((8#$env_mode & 7)) -eq 0 ]; then
        ok ".env tidak dapat dibaca pengguna lain (mode ${env_mode})"
    else
        fail ".env terlalu terbuka; gunakan mode 640 atau lebih ketat"
    fi

    if run_as_runtime_user test -r "$APP_DIR/.env"; then
        ok "User PHP-FPM ${PHP_FPM_RUNTIME_USER} dapat membaca .env"
    else
        fail "User PHP-FPM ${PHP_FPM_RUNTIME_USER} tidak dapat membaca .env"
    fi
else
    fail ".env tidak ditemukan di APP_DIR"
fi

for directory in "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"; do
    if run_as_runtime_user test -w "$directory"; then
        ok "User PHP-FPM ${PHP_FPM_RUNTIME_USER} dapat menulis: ${directory#$APP_DIR/}"
    else
        fail "User PHP-FPM ${PHP_FPM_RUNTIME_USER} tidak dapat menulis: ${directory#$APP_DIR/}"
    fi
done

if [ "$CHECK_SERVICES" = 'true' ]; then
    service_slug="$(printf '%s' "$DOMAIN" | tr -cs 'A-Za-z0-9' '-')"
    for service in "sita-${service_slug}-reverb.service" "sita-${service_slug}-queue.service" "sita-${service_slug}-schedule.timer"; do
        if systemctl is-active "$service" >/dev/null 2>&1; then
            ok "Service aktif: ${service}"
        else
            warn "Service belum aktif: ${service}"
        fi
    done
fi

printf '\nPeran operasional:\n'
printf '%s\n' '  GUI aaPanel: website satu kali, PHP/extension, database, SSL, log, dan monitoring.'
printf '%s\n' '  Git dan skrip: source, build, cache, migrasi terkontrol, service, dan security/integration gate.'
printf '%s\n' '  Extension PHP: boleh diubah hanya setelah runtime PHP dipastikan tidak dipakai situs lain atau setelah maintenance window disetujui.'
printf '%s\n' '  Sinkronisasi ini hanya membaca dan memverifikasi; tidak menimpa SSL atau konfigurasi GUI.'

if [ "$FAILED" -ne 0 ]; then
    printf '\nSynchronization check gagal. Perbaiki item [FAIL] pada lapisan yang disebutkan.\n' >&2
    exit 1
fi

if [ "$WARNED" -ne 0 ]; then
    printf '\nSynchronization check lulus dengan peringatan.\n'
else
    printf '\nSynchronization check lulus.\n'
fi
