#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

DOMAIN="${DOMAIN:?Isi DOMAIN, contoh: DOMAIN=sita.kampus.ac.id bash deploy/aapanel-deploy.sh}"
PHP_BIN="${PHP_BIN:-php}"
COMPOSER_BIN="${COMPOSER_BIN:-composer}"
NODE_BIN="${NODE_BIN:-node}"
NPM_BIN="${NPM_BIN:-npm}"
GIT_PULL="${GIT_PULL:-true}"
RUN_MIGRATIONS="${RUN_MIGRATIONS:-false}"
MIGRATION_MODE="${MIGRATION_MODE:-}"
RUN_QUEUE_RESTART="${RUN_QUEUE_RESTART:-true}"
INSTALL_SERVICES="${INSTALL_SERVICES:-false}"
RESTART_PHP_FPM="${RESTART_PHP_FPM:-true}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:-}"
PHP_FPM_RUNTIME_GROUP="${PHP_FPM_RUNTIME_GROUP:-www}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-}"
RUN_INTEGRATION_GATE="${RUN_INTEGRATION_GATE:-false}"
CHECK_SERVICES="${CHECK_SERVICES:-true}"
RUN_SECURITY_PREFLIGHT="${RUN_SECURITY_PREFLIGHT:-false}"
RUN_SECURITY_GATE="${RUN_SECURITY_GATE:-false}"
CHECK_DOCKER="${CHECK_DOCKER:-false}"
AAPANEL_DEPLOY_REEXECUTED="${AAPANEL_DEPLOY_REEXECUTED:-false}"
DEPLOY_TEMPORARY_DIRECTORY=""
DB_BACKUP_DEFAULTS_FILE=""
DB_BACKUP_TEMPORARY_FILE=""
PENDING_MIGRATIONS=()
RUN_PENDING_MIGRATIONS=false
DB_BACKUP_DIR="${DB_BACKUP_DIR:-/var/backups/sita}"

export PATH="$(dirname "$PHP_BIN"):$PATH"

APP_WAS_DOWN=0

finish() {
    if [ -n "$DB_BACKUP_DEFAULTS_FILE" ]; then
        rm -f "$DB_BACKUP_DEFAULTS_FILE"
    fi

    if [ -n "$DB_BACKUP_TEMPORARY_FILE" ]; then
        rm -f "$DB_BACKUP_TEMPORARY_FILE"
    fi

    if [ "$APP_WAS_DOWN" -eq 1 ]; then
        "$PHP_BIN" artisan up >/dev/null 2>&1 || true
    fi

    if [ -n "$DEPLOY_TEMPORARY_DIRECTORY" ]; then
        rm -rf "$DEPLOY_TEMPORARY_DIRECTORY"
    fi
}
trap finish EXIT

step() {
    printf '\n==> %s\n' "$1"
}

require_file() {
    if [ ! -f "$1" ]; then
        printf 'File wajib tidak ditemukan: %s\n' "$1" >&2
        exit 1
    fi
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Command wajib tidak tersedia: %s\n' "$1" >&2
        exit 1
    fi
}

composer_supports_runtime_api() {
    "$COMPOSER_BIN" --version --no-ansi 2>/dev/null | "$PHP_BIN" -r '
        $output = trim(stream_get_contents(STDIN));
        preg_match("/Composer version ([0-9]+(?:\\.[0-9]+){1,2})/", $output, $matches);
        exit(isset($matches[1]) && version_compare($matches[1], "2.2.0", ">=") ? 0 : 1);
    '
}

prepare_composer_runtime() {
    if composer_supports_runtime_api; then
        return
    fi

    require_command curl
    require_command sha256sum

    step "Siapkan Composer 2 sementara"
    printf 'Composer global belum memenuhi Runtime API 2.2; menggunakan Composer sementara yang terverifikasi.\n'

    DEPLOY_TEMPORARY_DIRECTORY="$(mktemp -d)"
    local composer_phar="$DEPLOY_TEMPORARY_DIRECTORY/composer.phar"
    local checksum_file="$DEPLOY_TEMPORARY_DIRECTORY/composer.phar.sha256sum"
    local composer_wrapper="$DEPLOY_TEMPORARY_DIRECTORY/composer"
    local expected_checksum actual_checksum

    curl -fsSL --retry 3 --connect-timeout 10 https://getcomposer.org/download/latest-stable/composer.phar -o "$composer_phar"
    curl -fsSL --retry 3 --connect-timeout 10 https://getcomposer.org/download/latest-stable/composer.phar.sha256sum -o "$checksum_file"
    expected_checksum="$(awk '{print $1}' "$checksum_file")"
    actual_checksum="$(sha256sum "$composer_phar" | awk '{print $1}')"

    if [ -z "$expected_checksum" ] || [ "$expected_checksum" != "$actual_checksum" ]; then
        printf 'Checksum Composer sementara tidak sesuai; deployment dihentikan.\n' >&2
        exit 1
    fi

    printf '#!/usr/bin/env bash\nexec %q %q "$@"\n' "$PHP_BIN" "$composer_phar" > "$composer_wrapper"
    chmod 700 "$composer_wrapper"
    COMPOSER_BIN="$composer_wrapper"

    if ! composer_supports_runtime_api; then
        printf 'Composer sementara belum memenuhi Runtime API 2.2; deployment dihentikan.\n' >&2
        exit 1
    fi
}

normalize_generated_filament_assets() {
    local file_upload_asset='public/js/filament/forms/components/file-upload.js'

    if [ -f "$file_upload_asset" ]; then
        sed -i 's/[[:space:]]\+$//' "$file_upload_asset"
    fi
}

env_value() {
    key="$1"
    grep -E "^${key}=" .env | tail -n 1 | cut -d '=' -f 2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
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

resolve_migration_mode() {
    if [ -z "$MIGRATION_MODE" ]; then
        if [ "$RUN_MIGRATIONS" = 'true' ]; then
            MIGRATION_MODE='apply'
        else
            MIGRATION_MODE='prompt'
        fi
    fi

    case "$MIGRATION_MODE" in
        prompt|apply|skip) ;;
        *)
            printf 'MIGRATION_MODE harus prompt, apply, atau skip. Nilai sekarang: %s\n' "$MIGRATION_MODE" >&2
            exit 2
            ;;
    esac
}

detect_pending_migrations() {
    local status_output status_exit migration

    set +e
    status_output="$("$PHP_BIN" artisan migrate:status --pending --no-ansi 2>&1)"
    status_exit=$?
    set -e

    if [ "$status_exit" -gt 1 ]; then
        printf 'Status migration tidak dapat diperiksa. Deployment dihentikan sebelum maintenance mode.\n' >&2
        printf '%s\n' "$status_output" >&2
        exit 1
    fi

    PENDING_MIGRATIONS=()
    while IFS= read -r migration; do
        [ -n "$migration" ] && PENDING_MIGRATIONS+=("$migration")
    done < <(printf '%s\n' "$status_output" | sed -n -E 's/^[[:space:]]*([0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]{6}_[A-Za-z0-9_]+).*/\1/p')

    if [ "${#PENDING_MIGRATIONS[@]}" -eq 0 ]; then
        if [ "$status_exit" -eq 0 ]; then
            printf 'Tidak ada migration database tertunda.\n'
            return
        fi

        printf 'Migration tertunda terdeteksi, tetapi daftar migration tidak dapat dibaca. Deployment dihentikan sebelum maintenance mode.\n' >&2
        printf '%s\n' "$status_output" >&2
        exit 1
    fi

    printf 'Ditemukan %s migration database tertunda:\n' "${#PENDING_MIGRATIONS[@]}"
    for migration in "${PENDING_MIGRATIONS[@]}"; do
        printf '  - %s\n' "$migration"
    done

    case "$MIGRATION_MODE" in
        skip)
            printf 'Migration tertunda tetapi MIGRATION_MODE=skip. Release dihentikan agar kode baru tidak aktif pada struktur database lama.\n' >&2
            exit 1
            ;;
        apply)
            printf 'Migration disetujui melalui MIGRATION_MODE=apply. Backup otomatis akan dibuat.\n'
            RUN_PENDING_MIGRATIONS=true
            ;;
        prompt)
            if [ ! -t 0 ]; then
                printf 'Migration tertunda membutuhkan persetujuan interaktif. Jalankan dari konsol atau gunakan MIGRATION_MODE=apply setelah backup policy direview.\n' >&2
                exit 1
            fi

            local answer
            read -r -p 'Buat backup database otomatis lalu terapkan migration ini? [y/N]: ' answer
            case "$answer" in
                y|Y|yes|YES)
                    RUN_PENDING_MIGRATIONS=true
                    printf 'Migration disetujui. Backup otomatis akan dibuat sebelum migration dijalankan.\n'
                    ;;
                *)
                    printf 'Release dibatalkan sebelum maintenance mode, backup, dan migration.\n' >&2
                    exit 1
                    ;;
            esac
            ;;
    esac
}

create_database_backup() {
    local db_connection db_host db_port db_database db_username db_password dump_bin backup_dir backup_slug run_id defaults_file backup_tmp backup_file checksum_file

    db_connection="$(env_value DB_CONNECTION)"
    case "$db_connection" in
        mysql|mariadb) ;;
        *)
            printf 'Backup otomatis migration saat ini mendukung MySQL/MariaDB. DB_CONNECTION sekarang: %s\n' "${db_connection:-kosong}" >&2
            exit 1
            ;;
    esac

    db_host="$(env_value DB_HOST)"
    db_port="$(env_value DB_PORT)"
    db_database="$(env_value DB_DATABASE)"
    db_username="$(env_value DB_USERNAME)"
    db_password="$(env_value DB_PASSWORD)"
    if [ -z "$db_host" ] || [ -z "$db_port" ] || [ -z "$db_database" ] || [ -z "$db_username" ]; then
        printf 'Konfigurasi database pada .env belum lengkap. Backup otomatis dibatalkan.\n' >&2
        exit 1
    fi

    dump_bin="$(command -v mysqldump || command -v mariadb-dump || true)"
    if [ -z "$dump_bin" ]; then
        printf 'mysqldump atau mariadb-dump tidak tersedia. Backup otomatis dibatalkan.\n' >&2
        exit 1
    fi
    require_command gzip
    require_command sha256sum

    if [[ "$DB_BACKUP_DIR" != /* ]]; then
        printf 'DB_BACKUP_DIR harus memakai path absolut. Nilai sekarang: %s\n' "$DB_BACKUP_DIR" >&2
        exit 2
    fi

    backup_dir="$DB_BACKUP_DIR"
    if [ ! -d "$backup_dir" ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo install -d -m 700 -o "$(id -un)" -g "$(id -gn)" "$backup_dir"
        else
            install -d -m 700 "$backup_dir"
        fi
    fi
    if [ ! -w "$backup_dir" ]; then
        printf 'Direktori backup tidak dapat ditulis: %s\n' "$backup_dir" >&2
        exit 1
    fi

    backup_slug="$(printf '%s' "$DOMAIN" | tr -cs 'A-Za-z0-9' '-')"
    run_id="$(date -u +%Y%m%dT%H%M%SZ)"
    backup_file="${backup_dir}/sita-${backup_slug}-${run_id}.sql.gz"
    checksum_file="${backup_file}.sha256"
    defaults_file="$(mktemp)"
    DB_BACKUP_DEFAULTS_FILE="$defaults_file"
    backup_tmp="$(mktemp "${backup_dir}/.sita-${backup_slug}-${run_id}.sql.gz.tmp.XXXXXX")"
    DB_BACKUP_TEMPORARY_FILE="$backup_tmp"
    chmod 600 "$defaults_file" "$backup_tmp"

    cat > "$defaults_file" <<EOF
[client]
host=${db_host}
port=${db_port}
user=${db_username}
password=${db_password}
EOF

    printf 'Membuat backup MySQL/MariaDB sebelum migration...\n'
    if ! "$dump_bin" --defaults-extra-file="$defaults_file" --single-transaction --routines --triggers --no-tablespaces --databases "$db_database" | gzip -c > "$backup_tmp"; then
        rm -f "$defaults_file" "$backup_tmp"
        DB_BACKUP_DEFAULTS_FILE=""
        DB_BACKUP_TEMPORARY_FILE=""
        printf 'Backup database gagal; migration tidak dijalankan.\n' >&2
        exit 1
    fi
    rm -f "$defaults_file"
    DB_BACKUP_DEFAULTS_FILE=""

    if [ ! -s "$backup_tmp" ] || ! gzip -t "$backup_tmp"; then
        rm -f "$backup_tmp"
        DB_BACKUP_TEMPORARY_FILE=""
        printf 'Backup database tidak valid atau kosong; migration tidak dijalankan.\n' >&2
        exit 1
    fi

    mv "$backup_tmp" "$backup_file"
    DB_BACKUP_TEMPORARY_FILE=""
    chmod 600 "$backup_file"
    sha256sum "$backup_file" > "$checksum_file"
    chmod 600 "$checksum_file"

    printf '[OK] Backup database valid: %s\n' "$backup_file"
    printf '[OK] Checksum backup: %s\n' "$checksum_file"
}

validate_php_runtime() {
    if ! "$PHP_BIN" -r 'exit(version_compare(PHP_VERSION, "8.4.0", ">=") ? 0 : 1);' >/dev/null 2>&1; then
        printf 'PHP CLI harus 8.4 atau lebih baru. Versi sekarang: %s\n' "$("$PHP_BIN" -r 'echo PHP_VERSION;' 2>/dev/null || printf 'unknown')" >&2
        exit 1
    fi

    if ! read_php_extensions; then
        printf 'Daftar PHP extension tidak dapat dibaca dari %s\n' "$PHP_BIN" >&2
        exit 1
    fi

    missing_extensions=0
    for extension in bcmath ctype dom fileinfo filter intl json mbstring openssl pcntl pcre pdo session tokenizer xml zip; do
        if ! php_extension_active "$extension"; then
            printf 'PHP extension wajib belum aktif: %s\n' "$extension" >&2
            missing_extensions=1
        fi
    done

    db_connection="$(env_value DB_CONNECTION)"
    case "$db_connection" in
        mysql|mariadb)
            if ! php_extension_active pdo_mysql; then
                printf 'PHP extension wajib belum aktif untuk %s: pdo_mysql\n' "$db_connection" >&2
                missing_extensions=1
            fi
            ;;
        pgsql)
            if ! php_extension_active pdo_pgsql; then
                printf 'PHP extension wajib belum aktif untuk pgsql: pdo_pgsql\n' >&2
                missing_extensions=1
            fi
            ;;
    esac

    if [ "$missing_extensions" -eq 1 ]; then
        exit 1
    fi
}

validate_node_runtime() {
    node_version="$("$NODE_BIN" -p 'process.versions.node' 2>/dev/null || true)"
    if [ -z "$node_version" ]; then
        printf 'Node.js tidak bisa dijalankan lewat NODE_BIN=%s\n' "$NODE_BIN" >&2
        exit 1
    fi

    if ! "$NODE_BIN" -e '
        const [major, minor] = process.versions.node.split(".").map(Number);
        process.exit((major === 20 && minor >= 19) || major === 21 || (major === 22 && minor >= 12) || major > 22 ? 0 : 1);
    ' >/dev/null 2>&1; then
        printf 'Node.js minimal 20.19 atau 22.12 dibutuhkan untuk Vite 7. Versi sekarang: %s\n' "$node_version" >&2
        exit 1
    fi
}

derive_php_fpm_service() {
    if [ -n "$PHP_FPM_SERVICE" ]; then
        printf '%s' "$PHP_FPM_SERVICE"
        return 0
    fi

    case "$PHP_BIN" in
        */php/[0-9][0-9]/bin/php)
            php_slot="$(printf '%s' "$PHP_BIN" | sed -E 's#^.*/php/([0-9][0-9])/bin/php$#\1#')"
            printf 'php-fpm-%s' "$php_slot"
            ;;
    esac
}

restart_php_fpm() {
    if [ "$RESTART_PHP_FPM" != "true" ]; then
        return 0
    fi

    service_name="$(derive_php_fpm_service || true)"
    if [ -z "$service_name" ]; then
        printf 'Lewati restart PHP-FPM: isi PHP_FPM_SERVICE jika service aaPanel tidak standar.\n'
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if command -v sudo >/dev/null 2>&1; then
            sudo systemctl reload-or-restart "$service_name" || sudo systemctl restart "$service_name"
        else
            systemctl reload-or-restart "$service_name" || systemctl restart "$service_name"
        fi
        return 0
    fi

    if [ -x "/etc/init.d/${service_name}" ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo "/etc/init.d/${service_name}" reload || sudo "/etc/init.d/${service_name}" restart
        else
            "/etc/init.d/${service_name}" reload || "/etc/init.d/${service_name}" restart
        fi
        return 0
    fi

    printf 'Lewati restart PHP-FPM: service %s tidak ditemukan.\n' "$service_name"
}

prepare_runtime_permissions() {
    local runtime_group="$PHP_FPM_RUNTIME_GROUP"

    if ! getent group "$runtime_group" >/dev/null 2>&1; then
        printf 'Group runtime PHP-FPM tidak ditemukan: %s\n' "$runtime_group" >&2
        exit 1
    fi

    mkdir -p storage/app/public storage/app/private storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs bootstrap/cache

    if command -v sudo >/dev/null 2>&1; then
        sudo chgrp -R "$runtime_group" storage bootstrap/cache
        sudo chgrp "$runtime_group" .env
        sudo chmod -R ug+rwX storage bootstrap/cache
        sudo chmod 640 .env
    else
        chgrp -R "$runtime_group" storage bootstrap/cache
        chgrp "$runtime_group" .env
        chmod -R ug+rwX storage bootstrap/cache
        chmod 640 .env
    fi
}

run_healthcheck() {
    if [ -z "$HEALTHCHECK_URL" ]; then
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        printf 'curl tidak tersedia, healthcheck %s dilewati.\n' "$HEALTHCHECK_URL"
        return 0
    fi

    step "Healthcheck production"
    for attempt in $(seq 1 20); do
        if curl -fsS "$HEALTHCHECK_URL" >/dev/null; then
            printf 'Healthcheck berhasil: %s\n' "$HEALTHCHECK_URL"
            return 0
        fi

        sleep 3
    done

    printf 'Healthcheck gagal setelah beberapa percobaan: %s\n' "$HEALTHCHECK_URL" >&2
    if [ -f storage/logs/laravel.log ]; then
        printf '\nTail log Laravel terakhir:\n' >&2
        tail -n 80 storage/logs/laravel.log >&2 || true
    fi
    exit 1
}

step "Validasi project"
require_file artisan
require_file composer.json
require_file package.json
require_file .env
require_command "$PHP_BIN"
require_command "$COMPOSER_BIN"
require_command "$NODE_BIN"
require_command "$NPM_BIN"
prepare_composer_runtime

if grep -q '^APP_ENV=production' .env && grep -q '^APP_DEBUG=false' .env; then
    printf 'Environment production terdeteksi.\n'
else
    printf 'APP_ENV harus production dan APP_DEBUG harus false di .env.\n' >&2
    exit 1
fi

if [ "$RUN_SECURITY_PREFLIGHT" = "true" ]; then
    step "Jalankan DevSecOps security preflight"
    CHECK_HTTP=false \
        CHECK_DOCKER="$CHECK_DOCKER" \
        NGINX_CONFIG="${NGINX_CONFIG:-}" \
        bash scripts/security-gate.sh
fi

if [ "$GIT_PULL" = "true" ] && [ -d .git ]; then
    step "Update source dari git"
    git pull --ff-only

    if [ "$AAPANEL_DEPLOY_REEXECUTED" != "true" ]; then
        step "Reload script deploy terbaru"
        export AAPANEL_DEPLOY_REEXECUTED=true
        exec "$BASH" "$0"
    fi
fi

if [ "${RUN_DEPENDENCY_AUDIT:-false}" = "true" ]; then
    step "Jalankan audit dependency production"
    PHP_BIN="$PHP_BIN" \
        COMPOSER_BIN="$COMPOSER_BIN" \
        NPM_BIN="$NPM_BIN" \
        bash scripts/dependency-security-audit.sh
fi

step "Validasi runtime production"
validate_php_runtime
validate_node_runtime
resolve_migration_mode

step "Periksa migration database"
detect_pending_migrations

step "Aktifkan maintenance mode"
if [ -f vendor/autoload.php ]; then
    "$PHP_BIN" artisan down --render="errors::503" --retry=60 || true
    APP_WAS_DOWN=1
else
    printf 'Lewati maintenance mode karena vendor/autoload.php belum ada.\n'
fi

step "Install dependency PHP production"
"$COMPOSER_BIN" install --no-dev --prefer-dist --optimize-autoloader --no-interaction
normalize_generated_filament_assets
"$COMPOSER_BIN" check-platform-reqs --no-dev

step "Install dependency frontend"
if [ -f package-lock.json ]; then
    "$NPM_BIN" ci
else
    "$NPM_BIN" install
fi

step "Build frontend production"
"$NPM_BIN" run build
rm -f public/hot

step "Siapkan storage dan permission"
prepare_runtime_permissions
"$PHP_BIN" artisan storage:link --force

step "Bersihkan cache bootstrap lama"
"$PHP_BIN" artisan config:clear
"$PHP_BIN" artisan route:clear
"$PHP_BIN" artisan view:clear
"$PHP_BIN" artisan event:clear

if [ "$RUN_PENDING_MIGRATIONS" = "true" ]; then
    step "Backup database sebelum migration"
    create_database_backup

    step "Jalankan migrasi database"
    "$PHP_BIN" artisan migrate --force
fi

"$PHP_BIN" artisan cache:clear || true

step "Cache konfigurasi production"
"$PHP_BIN" artisan config:cache
"$PHP_BIN" artisan route:cache
"$PHP_BIN" artisan view:cache
"$PHP_BIN" artisan event:cache

if [ "$RUN_QUEUE_RESTART" = "true" ]; then
    step "Restart queue worker Laravel"
    "$PHP_BIN" artisan queue:restart
fi

step "Restart PHP-FPM aaPanel"
restart_php_fpm

if [ "$INSTALL_SERVICES" = "true" ]; then
    step "Install/restart service Reverb, queue, dan scheduler"
    DOMAIN="$DOMAIN" PHP_BIN="$PHP_BIN" bash deploy/aapanel-services.sh
fi

step "Matikan maintenance mode"
"$PHP_BIN" artisan up
APP_WAS_DOWN=0

run_healthcheck

if [ "$RUN_INTEGRATION_GATE" = "true" ]; then
    step "Jalankan integration gate aaPanel"
    DOMAIN="$DOMAIN" \
        PHP_BIN="$PHP_BIN" \
        PHP_FPM_SERVICE="$(derive_php_fpm_service || true)" \
        PHP_FPM_RUNTIME_USER="${PHP_FPM_RUNTIME_USER:-$PHP_FPM_RUNTIME_GROUP}" \
        HEALTHCHECK_URL="$HEALTHCHECK_URL" \
        CHECK_SERVICES="$CHECK_SERVICES" \
        bash deploy/aapanel-integration-gate.sh
fi

if [ "$RUN_SECURITY_GATE" = "true" ]; then
    step "Jalankan DevSecOps security gate"
    PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-${HEALTHCHECK_URL%/up}}" \
        NGINX_CONFIG="${NGINX_CONFIG:-}" \
        CHECK_DOCKER="$CHECK_DOCKER" \
        bash scripts/security-gate.sh
fi

printf '\nDeploy selesai untuk %s.\n' "$DOMAIN"
printf 'Pastikan aaPanel Nginx root mengarah ke: %s/public\n' "$PROJECT_ROOT"
