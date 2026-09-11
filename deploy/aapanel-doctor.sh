#!/usr/bin/env bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

PHP_BIN="${PHP_BIN:-php}"
COMPOSER_BIN="${COMPOSER_BIN:-composer}"
NODE_BIN="${NODE_BIN:-node}"
NPM_BIN="${NPM_BIN:-npm}"
DOMAIN="${DOMAIN:-}"
CHECK_SERVICES="${CHECK_SERVICES:-false}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-}"

FAILED=0

ok() {
    printf '[OK] %s\n' "$1"
}

warn() {
    printf '[WARN] %s\n' "$1"
}

fail() {
    printf '[FAIL] %s\n' "$1"
    FAILED=1
}

need_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "Command tersedia: $1"
    else
        fail "Command tidak tersedia: $1"
    fi
}

env_value() {
    key="$1"
    if [ ! -f .env ]; then
        return 0
    fi

    grep -E "^${key}=" .env | tail -n 1 | cut -d '=' -f 2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

printf 'SITA aaPanel doctor\n'
printf 'Project root: %s\n\n' "$PROJECT_ROOT"

need_cmd "$PHP_BIN"
need_cmd "$COMPOSER_BIN"
need_cmd "$NODE_BIN"
need_cmd "$NPM_BIN"
need_cmd git
need_cmd bash

if command -v "$PHP_BIN" >/dev/null 2>&1; then
    PHP_VERSION_STR="$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null || true)"
    if "$PHP_BIN" -r 'exit(version_compare(PHP_VERSION, "8.4.0", ">=") ? 0 : 1);' >/dev/null 2>&1; then
        ok "PHP CLI ${PHP_VERSION_STR} memenuhi minimal 8.4"
    else
        fail "PHP CLI ${PHP_VERSION_STR:-unknown} belum memenuhi minimal 8.4"
    fi

    for extension in bcmath ctype dom fileinfo filter intl json mbstring openssl pcntl pcre pdo session tokenizer xml zip; do
        if "$PHP_BIN" -m | grep -qi "^${extension}$"; then
            ok "PHP extension aktif: ${extension}"
        else
            fail "PHP extension belum aktif: ${extension}"
        fi
    done
fi

if command -v "$COMPOSER_BIN" >/dev/null 2>&1 && command -v "$PHP_BIN" >/dev/null 2>&1; then
    COMPOSER_RUNTIME_API_VERSION="$("$COMPOSER_BIN" show -p composer-runtime-api --format=json 2>/dev/null | "$PHP_BIN" -r '$platform = json_decode(stream_get_contents(STDIN), true); echo is_array($platform) ? ($platform["version"] ?? $platform["versions"][0] ?? "") : "";' 2>/dev/null || true)"

    if "$PHP_BIN" -r 'exit(version_compare($argv[1], "2.2.0", ">=") ? 0 : 1);' "$COMPOSER_RUNTIME_API_VERSION" >/dev/null 2>&1; then
        ok "Composer runtime API ${COMPOSER_RUNTIME_API_VERSION} memenuhi minimal 2.2"
    else
        warn "Composer runtime API ${COMPOSER_RUNTIME_API_VERSION:-unknown} belum memenuhi minimal 2.2. Skrip deploy akan memakai Composer sementara terverifikasi tanpa mengubah Composer global aaPanel."
    fi
fi

if command -v "$NODE_BIN" >/dev/null 2>&1; then
    NODE_VERSION_STR="$("$NODE_BIN" -p 'process.versions.node' 2>/dev/null || true)"
    if "$NODE_BIN" -e '
        const [major, minor] = process.versions.node.split(".").map(Number);
        process.exit((major === 20 && minor >= 19) || major === 21 || (major === 22 && minor >= 12) || major > 22 ? 0 : 1);
    ' >/dev/null 2>&1; then
        ok "Node.js ${NODE_VERSION_STR} memenuhi minimal 20.19/22.12 untuk Vite 7"
    else
        fail "Node.js ${NODE_VERSION_STR:-unknown} belum memenuhi minimal 20.19 atau 22.12 untuk Vite 7"
    fi
fi

if [ -f composer.json ]; then
    ok "composer.json ditemukan"
else
    fail "composer.json tidak ditemukan"
fi

if [ -f package.json ]; then
    ok "package.json ditemukan"
else
    fail "package.json tidak ditemukan"
fi

if [ -f package-lock.json ]; then
    ok "package-lock.json ditemukan, deploy akan memakai npm ci"
else
    warn "package-lock.json tidak ditemukan, deploy akan fallback ke npm install"
fi

if [ -f public/hot ]; then
    warn "public/hot masih ada. Deploy akan menghapusnya agar production memakai public/build."
fi

if [ -f public/build/manifest.json ]; then
    ok "Asset manifest production tersedia: public/build/manifest.json"
else
    warn "Asset manifest production belum ada. Jalankan deploy agar npm run build membuat public/build."
fi

if [ -f .env ]; then
    ok ".env production ditemukan"
else
    fail ".env belum ada. Salin .env.production.example menjadi .env lalu isi nilai server."
fi

if [ -f .env ]; then
    APP_ENV_VALUE="$(env_value APP_ENV)"
    APP_DEBUG_VALUE="$(env_value APP_DEBUG)"
    APP_URL_VALUE="$(env_value APP_URL)"
    APP_KEY_VALUE="$(env_value APP_KEY)"
    DB_CONNECTION_VALUE="$(env_value DB_CONNECTION)"
    QUEUE_CONNECTION_VALUE="$(env_value QUEUE_CONNECTION)"
    BROADCAST_CONNECTION_VALUE="$(env_value BROADCAST_CONNECTION)"
    REVERB_HOST_VALUE="$(env_value REVERB_HOST)"
    REVERB_PORT_VALUE="$(env_value REVERB_PORT)"
    REVERB_INTERNAL_HOST_VALUE="$(env_value REVERB_INTERNAL_HOST)"
    REVERB_INTERNAL_PORT_VALUE="$(env_value REVERB_INTERNAL_PORT)"
    REVERB_INTERNAL_SCHEME_VALUE="$(env_value REVERB_INTERNAL_SCHEME)"

    [ "$APP_ENV_VALUE" = "production" ] && ok "APP_ENV=production" || fail "APP_ENV harus production, sekarang: ${APP_ENV_VALUE:-kosong}"
    [ "$APP_DEBUG_VALUE" = "false" ] && ok "APP_DEBUG=false" || fail "APP_DEBUG harus false, sekarang: ${APP_DEBUG_VALUE:-kosong}"
    [ -n "$APP_KEY_VALUE" ] && ok "APP_KEY sudah terisi" || fail "APP_KEY masih kosong"
    [ -n "$APP_URL_VALUE" ] && ok "APP_URL terisi: $APP_URL_VALUE" || fail "APP_URL masih kosong"
    [ -n "$DB_CONNECTION_VALUE" ] && ok "DB_CONNECTION terisi: $DB_CONNECTION_VALUE" || fail "DB_CONNECTION masih kosong"
    [ -n "$QUEUE_CONNECTION_VALUE" ] && ok "QUEUE_CONNECTION terisi: $QUEUE_CONNECTION_VALUE" || fail "QUEUE_CONNECTION masih kosong"
    [ -n "$BROADCAST_CONNECTION_VALUE" ] && ok "BROADCAST_CONNECTION terisi: $BROADCAST_CONNECTION_VALUE" || warn "BROADCAST_CONNECTION kosong"

    if [ "$BROADCAST_CONNECTION_VALUE" = "reverb" ]; then
        [ -n "$REVERB_HOST_VALUE" ] && ok "REVERB_HOST terisi: $REVERB_HOST_VALUE" || fail "REVERB_HOST wajib untuk Reverb"
        [ "$REVERB_PORT_VALUE" = "443" ] && ok "REVERB_PORT=443 untuk browser HTTPS" || warn "REVERB_PORT sebaiknya 443 saat proxy lewat Nginx HTTPS, sekarang: ${REVERB_PORT_VALUE:-kosong}"
        [ "$REVERB_INTERNAL_HOST_VALUE" = "127.0.0.1" ] && ok "REVERB_INTERNAL_HOST=127.0.0.1" || warn "REVERB_INTERNAL_HOST sebaiknya 127.0.0.1, sekarang: ${REVERB_INTERNAL_HOST_VALUE:-kosong}"
        [ "$REVERB_INTERNAL_PORT_VALUE" = "8080" ] && ok "REVERB_INTERNAL_PORT=8080" || warn "REVERB_INTERNAL_PORT sebaiknya 8080, sekarang: ${REVERB_INTERNAL_PORT_VALUE:-kosong}"
        [ "$REVERB_INTERNAL_SCHEME_VALUE" = "http" ] && ok "REVERB_INTERNAL_SCHEME=http" || warn "REVERB_INTERNAL_SCHEME sebaiknya http, sekarang: ${REVERB_INTERNAL_SCHEME_VALUE:-kosong}"
    fi

    if [ "$DB_CONNECTION_VALUE" = "mysql" ] || [ "$DB_CONNECTION_VALUE" = "mariadb" ]; then
        if "$PHP_BIN" -m | grep -qi '^pdo_mysql$'; then
            ok "pdo_mysql aktif untuk ${DB_CONNECTION_VALUE}"
        else
            fail "pdo_mysql belum aktif, wajib untuk ${DB_CONNECTION_VALUE}"
        fi
    fi

    if [ -n "$DOMAIN" ] && [ -n "$APP_URL_VALUE" ]; then
        case "$APP_URL_VALUE" in
            *"$DOMAIN"*) ok "APP_URL sesuai DOMAIN=$DOMAIN" ;;
            *) warn "APP_URL tidak memuat DOMAIN=$DOMAIN. Pastikan domain production benar." ;;
        esac
    fi
fi

for dir in storage bootstrap/cache; do
    if [ -d "$dir" ]; then
        if [ -w "$dir" ]; then
            ok "Writable: $dir"
        else
            fail "Belum writable: $dir"
        fi
    else
        fail "Folder tidak ditemukan: $dir"
    fi
done

if [ -d vendor ] && [ -f artisan ] && [ -f .env ]; then
    if "$PHP_BIN" artisan --version >/dev/null 2>&1; then
        ok "Artisan bisa dijalankan"
    else
        fail "Artisan gagal dijalankan. Cek vendor, .env, dan APP_KEY."
    fi

    if "$PHP_BIN" artisan migrate:status --no-interaction >/dev/null 2>&1; then
        ok "Koneksi database dan tabel migrations bisa diakses"
    else
        fail "Database belum bisa diakses oleh Laravel. Cek DB_HOST, DB_DATABASE, DB_USERNAME, DB_PASSWORD, dan pdo_mysql."
    fi
else
    warn "Lewati cek Artisan/database karena vendor, artisan, atau .env belum lengkap."
fi

if [ "$CHECK_SERVICES" = "true" ]; then
    if command -v systemctl >/dev/null 2>&1 && [ -n "$DOMAIN" ]; then
        SERVICE_SLUG="$(printf '%s' "$DOMAIN" | tr -cs 'A-Za-z0-9' '-')"
        for service in "sita-${SERVICE_SLUG}-reverb.service" "sita-${SERVICE_SLUG}-queue.service" "sita-${SERVICE_SLUG}-schedule.timer"; do
            if systemctl is-active "$service" >/dev/null 2>&1; then
                ok "Service aktif: $service"
            else
                warn "Service belum aktif: $service"
            fi
        done
    else
        warn "Lewati cek service karena systemctl tidak ada atau DOMAIN kosong."
    fi
fi

if [ -n "$PHP_FPM_SERVICE" ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files "$PHP_FPM_SERVICE.service" >/dev/null 2>&1; then
        ok "PHP-FPM service ditemukan: $PHP_FPM_SERVICE"
    elif [ -x "/etc/init.d/${PHP_FPM_SERVICE}" ]; then
        ok "PHP-FPM init script ditemukan: $PHP_FPM_SERVICE"
    else
        warn "PHP_FPM_SERVICE=$PHP_FPM_SERVICE belum ditemukan lewat systemctl atau /etc/init.d"
    fi
elif [ "$PHP_BIN" != "php" ]; then
    case "$PHP_BIN" in
        */php/[0-9][0-9]/bin/php)
            PHP_SLOT="$(printf '%s' "$PHP_BIN" | sed -E 's#^.*/php/([0-9][0-9])/bin/php$#\1#')"
            warn "Deploy akan mencoba restart PHP-FPM service: php-fpm-${PHP_SLOT}. Override dengan PHP_FPM_SERVICE bila nama service berbeda."
            ;;
    esac
fi

if [ -n "$HEALTHCHECK_URL" ]; then
    if command -v curl >/dev/null 2>&1; then
        if curl -fsS "$HEALTHCHECK_URL" >/dev/null; then
            ok "Healthcheck URL bisa diakses: $HEALTHCHECK_URL"
        else
            warn "Healthcheck URL belum berhasil: $HEALTHCHECK_URL"
        fi
    else
        warn "curl tidak tersedia untuk mengecek HEALTHCHECK_URL"
    fi
fi

if [ "$FAILED" -eq 0 ]; then
    printf '\nDoctor selesai: server siap untuk deploy.\n'
else
    printf '\nDoctor menemukan masalah. Perbaiki item [FAIL] sebelum deploy.\n'
fi

exit "$FAILED"
