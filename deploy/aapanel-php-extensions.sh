#!/usr/bin/env bash
set -Eeuo pipefail

# Repairs PHP capabilities that are required by SITA but missing from an
# aaPanel PHP build. This runs only during a deliberate server bootstrap; a
# routine release must not mutate a PHP runtime shared by unrelated websites.

PHP_BIN="${PHP_BIN:-/www/server/php/84/bin/php}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-php-fpm-84}"
DOMAIN="${DOMAIN:-}"
NGINX_VHOST_DIR="${NGINX_VHOST_DIR:-/www/server/panel/vhost/nginx}"
ALLOW_SHARED_PHP_EXTENSION_CHANGE="${ALLOW_SHARED_PHP_EXTENSION_CHANGE:-false}"
BACKUP_ROOT="${PHP_EXTENSION_BACKUP_DIR:-/var/backups/sita/php-extensions}"

green=''
yellow=''
red=''
reset=''
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    green='\033[32m'
    yellow='\033[33m'
    red='\033[31m'
    reset='\033[0m'
fi

ok() {
    printf '%b[OK]%b %s\n' "$green" "$reset" "$*"
}

warn() {
    printf '%b[WARN]%b %s\n' "$yellow" "$reset" "$*"
}

fail() {
    printf '%b[FAIL]%b %s\n' "$red" "$reset" "$*" >&2
}

run_privileged() {
    if [ "${EUID}" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

php_extension_active() {
    "$PHP_BIN" -m 2>/dev/null | grep -qx "$1"
}

php_extension_active_with_ini() {
    "$PHP_BIN" -c "$1" -m 2>/dev/null | grep -qx "$2"
}

php_root() {
    dirname "$(dirname "$PHP_BIN")"
}

runtime_vhost_count() {
    local include_name
    include_name="enable-php-$(basename "$(php_root)").conf"

    run_privileged test -d "$NGINX_VHOST_DIR" || {
        printf '0'
        return
    }

    { run_privileged grep -rl --include='*.conf' -- "$include_name" "$NGINX_VHOST_DIR" 2>/dev/null || true; } | wc -l | tr -d ' '
}

restart_php_fpm() {
    local init_script="/etc/init.d/${PHP_FPM_SERVICE}"

    if [ -x "$init_script" ]; then
        run_privileged "$init_script" reload || run_privileged "$init_script" restart
        return
    fi

    run_privileged systemctl reload-or-restart "$PHP_FPM_SERVICE"
}

install_fileinfo() {
    local root source_archive extension_dir work extension_source built_module backup_dir ini_file cli_ini_file vhost_count had_previous_module fpm_config_ready cli_config_ready

    root="$(php_root)"
    source_archive="${root}/src.tar.gz"
    ini_file="${root}/etc/php.ini"
    cli_ini_file="${root}/etc/php-cli.ini"
    extension_dir="$("$PHP_BIN" -i 2>/dev/null | sed -n 's/^extension_dir => \(.*\) =>.*$/\1/p' | head -n 1)"
    vhost_count="$(runtime_vhost_count)"

    [ -x "${root}/bin/phpize" ] || { fail "phpize aaPanel tidak tersedia: ${root}/bin/phpize"; return 1; }
    [ -x "${root}/bin/php-config" ] || { fail "php-config aaPanel tidak tersedia: ${root}/bin/php-config"; return 1; }
    [ -f "$source_archive" ] || { fail "Source PHP aaPanel tidak tersedia: $source_archive"; return 1; }
    [ -n "$extension_dir" ] && [ -d "$extension_dir" ] || { fail 'extension_dir PHP tidak dapat ditentukan'; return 1; }

    if [ "$vhost_count" -gt 1 ] && [ "$ALLOW_SHARED_PHP_EXTENSION_CHANGE" != 'true' ]; then
        fail "PHP $(basename "$root") dipakai ${vhost_count} vhost. Bootstrap dihentikan sebelum mengubah runtime bersama. Gunakan maintenance window, uji situs lain, lalu set ALLOW_SHARED_PHP_EXTENSION_CHANGE=true bila perubahan sudah disetujui."
        return 1
    fi

    if [ "$vhost_count" -eq 0 ]; then
        fail 'Tidak dapat menemukan pemakai runtime PHP dari vhost aaPanel. Periksa NGINX_VHOST_DIR sebelum perubahan.'
        return 1
    elif [ "$vhost_count" -eq 1 ]; then
        ok 'PHP runtime hanya dipakai satu vhost aaPanel; pemasangan otomatis diizinkan.'
    else
        warn "Perubahan runtime bersama disetujui eksplisit untuk ${vhost_count} vhost."
    fi

    work="$(mktemp -d /tmp/sita-fileinfo-build.XXXXXX)"
    trap 'rm -rf -- "${work:-}"' EXIT
    backup_dir="${BACKUP_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-php$(basename "$root")"
    run_privileged install -d -m 750 "$backup_dir"
    tar -xzf "$source_archive" -C "$work"
    extension_source="$(find "$work" -path '*/ext/fileinfo' -type d -print -quit)"
    [ -n "$extension_source" ] || { fail 'Source extension fileinfo tidak ditemukan dalam src.tar.gz'; return 1; }

    printf 'Membangun extension fileinfo untuk PHP aaPanel...\n'
    if ! (
        cd "$extension_source"
        "${root}/bin/phpize"
        ./configure --with-php-config="${root}/bin/php-config" --enable-fileinfo=shared
        make -j1
    ) >"${work}/build.log" 2>&1; then
        tail -n 40 "${work}/build.log" >&2
        fail "Build fileinfo gagal. Log: ${backup_dir}/fileinfo-build.log"
        run_privileged cp -p "${work}/build.log" "${backup_dir}/fileinfo-build.log"
        return 1
    fi

    built_module="${extension_source}/modules/fileinfo.so"
    [ -f "$built_module" ] || { fail 'Build fileinfo tidak menghasilkan fileinfo.so'; return 1; }
    "$PHP_BIN" -n -d "extension=${built_module}" -m 2>/dev/null | grep -qx fileinfo || {
        fail 'Modul fileinfo hasil build tidak dapat dimuat oleh PHP aaPanel'
        return 1
    }

    run_privileged cp -p "${work}/build.log" "${backup_dir}/fileinfo-build.log"
    run_privileged cp -p "$ini_file" "${backup_dir}/php.ini.before-fileinfo"
    if [ -f "$cli_ini_file" ]; then
        run_privileged cp -p "$cli_ini_file" "${backup_dir}/php-cli.ini.before-fileinfo"
    fi
    had_previous_module=false
    if [ -f "${extension_dir}/fileinfo.so" ]; then
        run_privileged cp -p "${extension_dir}/fileinfo.so" "${backup_dir}/fileinfo.so.before"
        had_previous_module=true
    fi

    run_privileged install -m 644 "$built_module" "${extension_dir}/fileinfo.so"
    for config_file in "$ini_file" "$cli_ini_file"; do
        [ -f "$config_file" ] || continue
        # Use an absolute module path. aaPanel keeps separate FPM and CLI ini
        # files, and an extension_dir-only directive can otherwise load from a
        # different runtime configuration than the one this script verified.
        run_privileged sed -i -E '/^[[:space:]]*extension[[:space:]]*=[[:space:]]*(.*\/)?fileinfo(\.so)?[[:space:]]*$/d' "$config_file"
        printf '\nextension = %s/fileinfo.so\n' "$extension_dir" | run_privileged tee -a "$config_file" >/dev/null
    done

    restart_php_fpm
    sleep 1
    fpm_config_ready=false
    cli_config_ready=false
    if php_extension_active_with_ini "$ini_file" fileinfo; then
        fpm_config_ready=true
    fi
    if php_extension_active fileinfo; then
        cli_config_ready=true
    fi
    if [ "$fpm_config_ready" != true ] || [ "$cli_config_ready" != true ]; then
        run_privileged cp -p "${backup_dir}/php.ini.before-fileinfo" "$ini_file"
        if [ -f "${backup_dir}/php-cli.ini.before-fileinfo" ]; then
            run_privileged cp -p "${backup_dir}/php-cli.ini.before-fileinfo" "$cli_ini_file"
        fi
        if [ "$had_previous_module" = true ]; then
            run_privileged cp -p "${backup_dir}/fileinfo.so.before" "${extension_dir}/fileinfo.so"
        else
            run_privileged rm -f "${extension_dir}/fileinfo.so"
        fi
        restart_php_fpm || true
        fail "fileinfo belum aktif setelah reload (FPM=${fpm_config_ready}, CLI=${cli_config_ready}); runtime dipulihkan. Backup tersedia di ${backup_dir}"
        return 1
    fi
    ok "Extension fileinfo aktif. Backup PHP tersimpan di: ${backup_dir}"
}

if [ ! -x "$PHP_BIN" ]; then
    fail "PHP aaPanel tidak ditemukan: $PHP_BIN"
    exit 1
fi

if php_extension_active fileinfo && php_extension_active_with_ini "$(php_root)/etc/php.ini" fileinfo; then
    ok 'Extension fileinfo sudah aktif; tidak ada perubahan runtime PHP.'
    exit 0
fi

printf 'Extension fileinfo belum aktif; menjalankan perbaikan runtime terkontrol.\n'
install_fileinfo
