#!/usr/bin/env bash
set -Eeuo pipefail

# Builds an immutable candidate beside the Git control checkout. Nginx and the
# systemd workers always point at CURRENT_LINK, so changing one symlink is the
# only operation that exposes a new release to users.

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROL_DIR="${APP_DIR:-$SCRIPT_ROOT}"
DOMAIN="${DOMAIN:?Isi DOMAIN sebelum menjalankan atomic release}"
PHP_BIN="${PHP_BIN:-/www/server/php/84/bin/php}"
COMPOSER_BIN="${COMPOSER_BIN:-composer}"
NPM_BIN="${NPM_BIN:-npm}"
PHP_FPM_SERVICE="${PHP_FPM_SERVICE:?PHP_FPM_SERVICE wajib diisi}"
PHP_FPM_RUNTIME_GROUP="${PHP_FPM_RUNTIME_GROUP:-www}"
PHP_FPM_RUNTIME_USER="${PHP_FPM_RUNTIME_USER:-www}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:?HEALTHCHECK_URL wajib diisi}"
NGINX_CONFIG="${NGINX_CONFIG:?NGINX_CONFIG wajib diisi}"
NGINX_BIN="${NGINX_BIN:-/www/server/nginx/sbin/nginx}"
RELEASE_ROOT="${RELEASE_ROOT:-${CONTROL_DIR}/.sita-release}"
RELEASES_DIR="${RELEASES_DIR:-${RELEASE_ROOT}/releases}"
SHARED_DIR="${SHARED_DIR:-${RELEASE_ROOT}/shared}"
CURRENT_LINK="${CURRENT_LINK:-${RELEASE_ROOT}/current}"
RELEASE_KEEP="${RELEASE_KEEP:-3}"
MANAGE_NGINX_ROOT="${MANAGE_NGINX_ROOT:-prompt}"
RELEASE_MIGRATION_POLICY="${RELEASE_MIGRATION_POLICY:-block}"

if [ ! -d "$CONTROL_DIR/.git" ]; then
    printf 'Atomic release membutuhkan checkout Git pada APP_DIR: %s\n' "$CONTROL_DIR" >&2
    exit 2
fi

if [[ "$RELEASE_ROOT" != /* ]] || [[ "$CURRENT_LINK" != "${RELEASE_ROOT}"/* ]]; then
    printf 'RELEASE_ROOT dan CURRENT_LINK harus berupa path absolut; CURRENT_LINK harus berada di RELEASE_ROOT.\n' >&2
    exit 2
fi

case "$RELEASE_MIGRATION_POLICY" in
    block) ;;
    *)
        printf 'RELEASE_MIGRATION_POLICY saat ini hanya mendukung block. Migration harus memakai alur migration gate terpisah.\n' >&2
        exit 2
        ;;
esac

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Command wajib tidak tersedia: %s\n' "$1" >&2
        exit 1
    fi
}

step() {
    printf '\n==> %s\n' "$1"
}

run_privileged() {
    if [ "$EUID" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

read_privileged() {
    if [ -r "$1" ]; then
        cat "$1"
    else
        run_privileged cat "$1"
    fi
}

DEPLOY_TEMPORARY_DIRECTORY=''
CANDIDATE_DIR=''
PREVIOUS_RELEASE=''
VHOST_BACKUP_FILE=''
ACTIVATED=false
COMPLETED=false
ROLLING_BACK=false

restart_runtime() {
    SERVICE_WORKING_DIR="$CURRENT_LINK" \
        DOMAIN="$DOMAIN" \
        PHP_BIN="$PHP_BIN" \
        SERVICE_GROUP="$PHP_FPM_RUNTIME_GROUP" \
        bash "$SCRIPT_ROOT/deploy/aapanel-services.sh"
    run_privileged systemctl restart "$PHP_FPM_SERVICE"
}

restore_previous_release() {
    [ "$ROLLING_BACK" = false ] || return
    ROLLING_BACK=true

    if [ -n "$PREVIOUS_RELEASE" ] && [ -f "$PREVIOUS_RELEASE/artisan" ]; then
        printf '\n[ROLLBACK] Mengembalikan current ke release sebelumnya: %s\n' "$(basename "$PREVIOUS_RELEASE")" >&2
        ln -s "$PREVIOUS_RELEASE" "${CURRENT_LINK}.rollback"
        mv -Tf "${CURRENT_LINK}.rollback" "$CURRENT_LINK"
        restart_runtime || true
        APP_DIR="$CURRENT_LINK" \
            DOMAIN="$DOMAIN" \
            PHP_BIN="$PHP_BIN" \
            PHP_FPM_SERVICE="$PHP_FPM_SERVICE" \
            PHP_FPM_RUNTIME_USER="$PHP_FPM_RUNTIME_USER" \
            HEALTHCHECK_URL="$HEALTHCHECK_URL" \
            bash "$SCRIPT_ROOT/deploy/aapanel-integration-gate.sh" || true
        printf '[ROLLBACK] Release sebelumnya kembali aktif.\n' >&2
        return
    fi

    if [ -n "$VHOST_BACKUP_FILE" ] && [ -f "$VHOST_BACKUP_FILE" ]; then
        printf '\n[ROLLBACK] Mengembalikan vhost aaPanel awal.\n' >&2
        run_privileged cp -p "$VHOST_BACKUP_FILE" "$NGINX_CONFIG" || true
        run_privileged "$NGINX_BIN" -t >/dev/null 2>&1 && run_privileged "$NGINX_BIN" -s reload || true
    fi

    rm -f "$CURRENT_LINK" "${CURRENT_LINK}.next" || true
    SERVICE_WORKING_DIR="$CONTROL_DIR" \
        DOMAIN="$DOMAIN" \
        PHP_BIN="$PHP_BIN" \
        SERVICE_GROUP="$PHP_FPM_RUNTIME_GROUP" \
        bash "$SCRIPT_ROOT/deploy/aapanel-services.sh" || true
    run_privileged systemctl restart "$PHP_FPM_SERVICE" || true
    printf '[ROLLBACK] Tidak ada release sebelumnya; konfigurasi aplikasi awal dipertahankan.\n' >&2
}

finish() {
    if [ "$ACTIVATED" = true ] && [ "$COMPLETED" = false ]; then
        restore_previous_release || true
    fi

    if [ -n "$DEPLOY_TEMPORARY_DIRECTORY" ]; then
        rm -rf "$DEPLOY_TEMPORARY_DIRECTORY"
    fi

    if [ -n "$CANDIDATE_DIR" ] && [ "$COMPLETED" = false ] && [ "$ACTIVATED" = false ]; then
        rm -rf "$CANDIDATE_DIR"
    fi
}
trap finish EXIT

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
    DEPLOY_TEMPORARY_DIRECTORY="$(mktemp -d)"
    local composer_phar="$DEPLOY_TEMPORARY_DIRECTORY/composer.phar"
    local checksum_file="$DEPLOY_TEMPORARY_DIRECTORY/composer.phar.sha256sum"
    local composer_wrapper="$DEPLOY_TEMPORARY_DIRECTORY/composer"
    local expected_checksum actual_checksum

    printf 'Composer global belum memenuhi Runtime API 2.2; menggunakan Composer sementara terverifikasi.\n'
    curl -fsSL --retry 3 --connect-timeout 10 https://getcomposer.org/download/latest-stable/composer.phar -o "$composer_phar"
    curl -fsSL --retry 3 --connect-timeout 10 https://getcomposer.org/download/latest-stable/composer.phar.sha256sum -o "$checksum_file"
    expected_checksum="$(awk '{print $1}' "$checksum_file")"
    actual_checksum="$(sha256sum "$composer_phar" | awk '{print $1}')"
    if [ -z "$expected_checksum" ] || [ "$expected_checksum" != "$actual_checksum" ]; then
        printf 'Checksum Composer sementara tidak sesuai.\n' >&2
        exit 1
    fi

    printf '#!/usr/bin/env bash\nexec %q %q "$@"\n' "$PHP_BIN" "$composer_phar" > "$composer_wrapper"
    chmod 700 "$composer_wrapper"
    COMPOSER_BIN="$composer_wrapper"
}

prepare_layout() {
    step 'Siapkan layout release dan shared runtime'
    run_privileged install -d -m 750 -o "$(id -un)" -g "$PHP_FPM_RUNTIME_GROUP" "$RELEASE_ROOT" "$RELEASES_DIR" "$SHARED_DIR"

    if [ ! -f "$SHARED_DIR/.env" ]; then
        [ -f "$CONTROL_DIR/.env" ] || { printf '.env awal tidak ditemukan pada control checkout.\n' >&2; exit 1; }
        cp -p "$CONTROL_DIR/.env" "$SHARED_DIR/.env"
    fi
    if [ ! -f "$SHARED_DIR/.sita-shared-storage-ready" ]; then
        require_command rsync
        run_privileged install -d -m 770 -o "$(id -un)" -g "$PHP_FPM_RUNTIME_GROUP" "$SHARED_DIR/storage"
        if [ -d "$CONTROL_DIR/storage" ]; then
            # Historical experiment artefacts can be owned by root. The
            # initial copy is privileged, then permissions are narrowed below.
            run_privileged rsync -a --delete "$CONTROL_DIR/storage/" "$SHARED_DIR/storage/"
        fi
    fi

    run_privileged chgrp "$PHP_FPM_RUNTIME_GROUP" "$SHARED_DIR/.env"
    run_privileged chmod 640 "$SHARED_DIR/.env"
    run_privileged chgrp -R "$PHP_FPM_RUNTIME_GROUP" "$SHARED_DIR/storage"
    run_privileged chmod -R ug+rwX "$SHARED_DIR/storage"
    touch "$SHARED_DIR/.sita-shared-storage-ready"
    chmod 640 "$SHARED_DIR/.sita-shared-storage-ready"
}

create_candidate() {
    step 'Ambil source dan buat candidate release'
    git -C "$CONTROL_DIR" pull --ff-only
    local revision release_id
    revision="$(git -C "$CONTROL_DIR" rev-parse --short=12 HEAD)"
    release_id="$(date -u +%Y%m%dT%H%M%SZ)-${revision}"
    CANDIDATE_DIR="${RELEASES_DIR}/${release_id}"
    [ ! -e "$CANDIDATE_DIR" ] || { printf 'Direktori release sudah ada: %s\n' "$CANDIDATE_DIR" >&2; exit 1; }
    install -d -m 750 "$CANDIDATE_DIR"
    git -C "$CONTROL_DIR" archive --format=tar HEAD | tar -x -C "$CANDIDATE_DIR"
    # Laravel tracks placeholder files in storage/. Replace this candidate-only
    # directory with the shared runtime so uploads and logs survive releases.
    rm -rf "$CANDIDATE_DIR/storage"
    ln -s "$SHARED_DIR/.env" "$CANDIDATE_DIR/.env"
    ln -s "$SHARED_DIR/storage" "$CANDIDATE_DIR/storage"
    install -d -m 770 "$CANDIDATE_DIR/bootstrap/cache"
    run_privileged chgrp -R "$PHP_FPM_RUNTIME_GROUP" "$CANDIDATE_DIR/bootstrap/cache"
    run_privileged chmod -R ug+rwX "$CANDIDATE_DIR/bootstrap/cache"
    printf 'Candidate release: %s\n' "$CANDIDATE_DIR"
}

build_candidate() {
    step 'Build candidate tanpa mengubah aplikasi aktif'
    cd "$CANDIDATE_DIR"
    prepare_composer_runtime
    "$COMPOSER_BIN" install --no-dev --prefer-dist --optimize-autoloader --no-interaction
    "$COMPOSER_BIN" check-platform-reqs --no-dev
    "$NPM_BIN" ci
    "$NPM_BIN" run build
    rm -f public/hot
    "$PHP_BIN" artisan storage:link --force
    "$PHP_BIN" artisan config:clear
    "$PHP_BIN" artisan route:clear
    "$PHP_BIN" artisan view:clear
    "$PHP_BIN" artisan event:clear
    "$PHP_BIN" artisan config:cache
    "$PHP_BIN" artisan route:cache
    "$PHP_BIN" artisan view:cache
    "$PHP_BIN" artisan event:cache
}

assert_no_pending_migrations() {
    step 'Periksa kompatibilitas migration candidate'
    local output status pending
    set +e
    output="$(cd "$CANDIDATE_DIR" && "$PHP_BIN" artisan migrate:status --pending --no-ansi 2>&1)"
    status=$?
    set -e
    pending="$(printf '%s\n' "$output" | sed -n -E 's/^[[:space:]]*([0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]{6}_[A-Za-z0-9_]+).*/\1/p')"
    if [ -n "$pending" ]; then
        printf 'Atomic rollback diblokir karena terdapat migration tertunda:\n%s\n' "$pending" >&2
        printf 'Gunakan migration yang backward-compatible dan jalur migration gate terkontrol sebelum mengaktifkan release atomic. Candidate tidak diaktifkan.\n' >&2
        exit 1
    fi
    if [ "$status" -ne 0 ]; then
        printf 'Status migration candidate tidak dapat diperiksa:\n%s\n' "$output" >&2
        exit 1
    fi
    printf 'Tidak ada migration tertunda; rollback kode aman dijalankan.\n'
}

ensure_nginx_points_to_current() {
    local expected old_root content updated answer backup_dir
    expected="root ${CURRENT_LINK}/public;"
    old_root="root ${CONTROL_DIR}/public;"
    content="$(read_privileged "$NGINX_CONFIG")"
    if grep -Fq "$expected" <<<"$content"; then
        printf 'Nginx sudah mengarah ke symlink current.\n'
        return
    fi
    if ! grep -Fq "$old_root" <<<"$content"; then
        printf 'Root Nginx tidak sesuai control checkout ataupun current release. Perbaiki melalui GUI aaPanel terlebih dahulu.\n' >&2
        exit 1
    fi

    case "$MANAGE_NGINX_ROOT" in
        true) ;;
        prompt)
            if [ ! -t 0 ]; then
                printf 'Perubahan root Nginx pertama kali membutuhkan terminal interaktif atau MANAGE_NGINX_ROOT=true.\n' >&2
                exit 1
            fi
            read -r -p "Ubah root vhost aaPanel ke current release dan buat backup konfigurasi? [y/N]: " answer
            case "$answer" in y|Y|yes|YES) ;; *) printf 'Aktivasi dibatalkan sebelum root Nginx diubah.\n' >&2; exit 1 ;; esac
            ;;
        *)
            printf 'MANAGE_NGINX_ROOT harus true atau prompt.\n' >&2
            exit 2
            ;;
    esac

    backup_dir='/var/backups/sita/nginx'
    run_privileged install -d -m 700 -o "$(id -un)" -g "$(id -gn)" "$backup_dir"
    VHOST_BACKUP_FILE="${backup_dir}/$(basename "$NGINX_CONFIG").$(date -u +%Y%m%dT%H%M%SZ).before-current.conf"
    run_privileged cp -p "$NGINX_CONFIG" "$VHOST_BACKUP_FILE"
    updated="${content//$old_root/$expected}"
    printf '%s\n' "$updated" | run_privileged tee "$NGINX_CONFIG" >/dev/null
    if ! run_privileged "$NGINX_BIN" -t >/dev/null 2>&1; then
        run_privileged cp -p "$VHOST_BACKUP_FILE" "$NGINX_CONFIG"
        printf 'Sintaks Nginx gagal setelah perubahan root; konfigurasi dipulihkan.\n' >&2
        exit 1
    fi
    run_privileged "$NGINX_BIN" -s reload
    printf '[OK] Root Nginx dialihkan ke %s\n' "$CURRENT_LINK/public"
    printf '[OK] Backup vhost: %s\n' "$VHOST_BACKUP_FILE"
}

activate_candidate() {
    step 'Aktifkan candidate secara atomik'
    if [ -L "$CURRENT_LINK" ]; then
        PREVIOUS_RELEASE="$(readlink -f "$CURRENT_LINK")"
    fi
    ln -s "$CANDIDATE_DIR" "${CURRENT_LINK}.next"
    if [ -n "$PREVIOUS_RELEASE" ]; then
        mv -Tf "${CURRENT_LINK}.next" "$CURRENT_LINK"
        ACTIVATED=true
        ensure_nginx_points_to_current
    else
        mv -Tf "${CURRENT_LINK}.next" "$CURRENT_LINK"
        ACTIVATED=true
        ensure_nginx_points_to_current
    fi
    restart_runtime
}

verify_candidate() {
    step 'Validasi pascaaktivasi dan keputusan rollback'
    APP_DIR="$CURRENT_LINK" \
        DOMAIN="$DOMAIN" \
        PHP_BIN="$PHP_BIN" \
        PHP_FPM_SERVICE="$PHP_FPM_SERVICE" \
        PHP_FPM_RUNTIME_USER="$PHP_FPM_RUNTIME_USER" \
        HEALTHCHECK_URL="$HEALTHCHECK_URL" \
        bash "$SCRIPT_ROOT/deploy/aapanel-integration-gate.sh"
    APP_DIR="$CURRENT_LINK" \
        PUBLIC_BASE_URL="${HEALTHCHECK_URL%/up}" \
        NGINX_CONFIG="$NGINX_CONFIG" \
        CHECK_DOCKER=false \
        bash "$SCRIPT_ROOT/scripts/security-gate.sh" --mode=warn --environment=aapanel
}

cleanup_releases() {
    local active previous item index=0 real
    active="$(readlink -f "$CURRENT_LINK")"
    previous="$PREVIOUS_RELEASE"
    while IFS= read -r item; do
        index=$((index + 1))
        [ "$index" -le "$RELEASE_KEEP" ] && continue
        real="$(readlink -f "$item")"
        case "$real" in
            "$RELEASES_DIR"/*) ;;
            *) printf 'Lewati cleanup path di luar RELEASES_DIR: %s\n' "$real" >&2; continue ;;
        esac
        if [ "$real" = "$active" ] || [ "$real" = "$previous" ]; then
            continue
        fi
        rm -rf -- "$real"
        printf 'Release lama dibersihkan: %s\n' "$(basename "$real")"
    done < <(find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -rn | awk '{print $2}')
}

for command in git tar rsync curl "$PHP_BIN" "$COMPOSER_BIN" "$NPM_BIN" sudo; do
    require_command "$command"
done

prepare_layout
create_candidate
build_candidate
assert_no_pending_migrations
activate_candidate
verify_candidate
cleanup_releases
COMPLETED=true

printf '\nATOMIC RELEASE DINYATAKAN SIAP\n'
printf 'Current release: %s\n' "$(readlink -f "$CURRENT_LINK")"
